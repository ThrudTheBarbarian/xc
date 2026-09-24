// XTIRLowering.m
//
// Single-function scope: walk the AST, emit IR. Locals live in a
// name → current XTIRValue map (SSA-style — assignment rebinds the
// name). Control-flow merges run the merge-and-phi routine over the
// per-predecessor local maps. Memory tokens thread through every
// memory-touching op; for the current subset (no Load/Store) the
// thread is trivial — entry Mem flows straight to the Return.
#import "XTIRLowering.h"
#import "XTIRElemKind.h"
#import "XTIR.h"
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTStmtNodes.h"
#import "XTExprNodes.h"
#import "XTType.h"
#import "XTPointerType.h"
#import "XTStructType.h"
#import "XTArrayType.h"
#import "XTEnumType.h"
#import "XTFloatEncoding.h"
#import "XTDiagnosticEngine.h"
#import "XTSourceLocation.h"

#pragma mark - Class lowering metadata

// Per-class derived shape: the instance layout, the vtable layout, the
// vtable symbol id, and quick-lookup maps for ivar offsets and virtual
// method slots. Populated in the pre-scan pass; consumed by method-body
// lowering and call sites.
@interface XTIRClassInfo : NSObject
@property(nonatomic, copy) NSString* className;
@property(nonatomic, nullable) XTIRClassInfo* parent;
@property(nonatomic) XTIRLayout* instanceLayout; // slot 0 = vtable ptr, then ivars
@property(nonatomic) XTIRLayout* vtableLayout;
@property(nonatomic) XTIRSymbolId vtableSymbolId;
@property(nonatomic) XTIRType* selfPtrType; // Ptr(Agg(instanceLayout), unbanked)
// ivar name → (field-index, AST type). Field 0 is the vtable pointer,
// so ivars start at index 1; inherited ivars keep their parent-side
// indices.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* ivarFieldIndex;
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* ivarASTType;
// `static u16 count;` — class-level storage, ONE copy shared by every
// instance and by the class's static methods. Such an ivar is deliberately
// absent from ivarFieldIndex and from the instance layout: it is a module
// global (`__sivar_<Class>_<name>`), and the name is bound to that global
// for the duration of the class's method bodies. Before this, the `static`
// was parsed and thrown away, so the same name meant per-instance storage
// in an instance method and the static block in a static one — two
// different variables wearing one name.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* staticIvarSymbol;
// Resolved virtual-dispatch slots — methodName → slot index. Holds the
// owning class's mangled symbol so direct calls can shortcut the
// vtable. Slots are parent-first to match the inheritance layout.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* methodSlot;
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* methodMangled;
// methodName → the method's declared (first) return type. The for-in
// lowering reads `enumLength`'s width from here rather than assuming one:
// a 32-bit Foundation declares `u32 enumLength()`, the 6502 one `u16`, and
// the loop's counter must be as wide as the count it compares against or
// the container silently stops enumerating at 65536.
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* methodReturnAST;
// One method-function symbol name per vtable slot, in slot order:
// `<DefiningClass>$<mangled>`. Seeded from the parent (so inherited,
// non-overridden slots keep the parent's symbol) and overwritten by
// this class's own methods. Copied onto the VTable symbol for emission.
@property(nonatomic) NSMutableArray<NSString*>* vtableEntrySymbolNames;
// YES iff this class participates in virtual/protocol dispatch — it
// conforms to ≥1 protocol, or inherits from a class that does. Only
// such classes get a VTable symbol emitted + their `new` sets the
// vtable pointer; non-dispatch classes skip both (no per-object cost,
// no code/data bloat). #58 lowers protocol calls only, so protocol
// conformance is the trigger.
@property(nonatomic) BOOL needsVtable;
// YES iff the program contains at least one `new <Class>` for this class
// (sema's usedByNew, propagated up the parent chain). Gates the static-init
// guard — see emitStaticInitGuardForClass:.
@property(nonatomic) BOOL usedByNew;
// Dense RTTI class id (1..N, 0 = unassigned). `new` stamps it into the
// instance's slot-0 word for non-vtable classes; the `as?`/`as` downcast
// reads it back and checks subtree membership. Assigned in lowerProgram.
@property(nonatomic) NSUInteger classId;
// Names of the ivars THIS class declares (not inherited). The dealloc
// teardown releases only own strong ivars and chains to super for the
// rest, so an inherited strong ivar is freed exactly once — by the
// ancestor that declares it.
@property(nonatomic) NSSet<NSString*>* ownIvarNames;
// §4.2 category chain. `catSlot` maps a method name to its CHAIN slot (0-based,
// numbered per extended class, independent of the vtable's slot space);
// `catChainHost` names the extended class, whose `<Host>$cat` table is the
// fallback a dispatch site uses when the receiver's chain word is null. Both
// empty unless this class is, or descends from, a class extended by a category
// declared in this module.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* catSlot;
@property(nonatomic, copy, nullable) NSString* catChainHost;
// §4.3b: the owner-anchor symbol — this compilation's fallback table for
// catChainHost (`<Host>$cat$<names>`). Dispatch selects it on a null OR
// foreign chain table; entry [0] of every family table holds its address.
@property(nonatomic, copy, nullable) NSString* catChainAnchor;
@end

@implementation XTIRClassInfo
@end

@interface XTIRLowering ()
@property(nonatomic) XTIRModule* module;
@property(nonatomic) XTDiagnosticEngine* diag;
@property(nonatomic) BOOL aborted;       // per-function abort flag
@property(nonatomic) BOOL nativeVarargs; // AAPCS va_list target (arm9)

// Module-level state, populated during pre-scan.
@property(nonatomic) NSMutableDictionary<NSString*, XTIRClassInfo*>* classesByName;
@property(nonatomic) NSMutableDictionary<NSString*, XTClassDeclNode*>* classDeclsByName;
// Classes whose preScanClass: is currently on the stack. A class-pointer
// type mapped BEFORE its class's pre-scan (a cyclic #import puts the user
// of a class ahead of the class itself in the merged unit) pre-scans it on
// demand; this set breaks the one unresolvable case — two classes whose
// IVARS point at each other — instead of recursing forever.
@property(nonatomic) NSMutableSet<NSString*>* preScanInProgress;
// Classes whose phase-2 pre-scan (vtable/itable/method symbols) has run.
@property(nonatomic) NSMutableSet<NSString*>* preScanRestDone;
// protocol name → its declaration, so a protocol-typed dispatch can widen its
// args to the method's declared parameter types (no concrete callee to read).
@property(nonatomic) NSMutableDictionary<NSString*, XTProtocolDeclNode*>* protocolDeclsByName;
// className → dense RTTI id (1..N), sorted by name for determinism.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* classIdByName;
// Class names whose user `dealloc` explicitly calls `super.dealloc()`,
// so the teardown must NOT auto-append a second super-chain call.
@property(nonatomic) NSMutableSet<NSString*>* deallocCallsSuper;

// Per-function state.
@property(nonatomic, nullable) XTIRFunction* currentFunction;
@property(nonatomic, nullable) XTIRBlock* currentBlock;
@property(nonatomic) NSMutableDictionary<NSString*, XTIRValue*>* locals; // name → current value
@property(nonatomic, nullable) XTIRValue* memToken;                      // current memory token

// Set while lowering a method body — used to resolve bare-identifier
// references to ivars and to bind `self` in the locals map.
@property(nonatomic, nullable) XTIRClassInfo* currentClassInfo;
@property(nonatomic, nullable) XTIRValue* currentSelf;

// Stack of enclosing loops — break / continue use the inner-most.
// Each entry is { headerBlock, exitBlock }.
@property(nonatomic) NSMutableArray<NSDictionary*>* loopStack;

// Stack of "scope" snapshots for ARC release-at-scope-exit. Each entry
// is the array of class-pointer local names that have been declared
// since that scope was pushed. On scope pop, we emit a Release for each
// name (in reverse declaration order — LIFO).
@property(nonatomic) NSMutableArray<NSMutableArray<NSString*>*>* arcScopeStack;
// goto/label: target-name → its IR block, and → its scope-nesting depth. Reset
// per function. (A C-porting aid; goto is undocumented as a language feature.)
@property(nonatomic) NSMutableDictionary<NSString*, XTIRBlock*>* labelBlocks;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* labelDepths;
// Shadow saves, parallel to arcScopeStack: frame i maps a local NAME that a
// declaration inside scope i SHADOWED to the outer binding's saved state
// (its `locals` value plus every name-keyed ARC/array/pinned table entry).
// The lowering's name tables are otherwise FLAT, so without this a
// `for (u32 t ...)` after a `String* t` rebound the name for the REST OF THE
// FUNCTION — the enclosing scope's exit release then released the loop
// counter as if it were the String (finding #16: SIGBUS after main returns),
// and any later read of the outer name saw the shadow's value.
@property(nonatomic) NSMutableArray<NSMutableDictionary<NSString*, NSDictionary*>*>* shadowSaveStack;
// Names that appear as the LHS of a plain `name = …` anywhere in the body,
// filled by the same pre-scan that finds `&`-taken locals. Only used to decide
// which class-pointer PARAMETERS have to become strong slots — see
// pendingStrongParams and private:docs/bugs/064.
@property(nonatomic) NSMutableSet<NSString*>* preScanAssignedNames;
// Class-pointer parameters this function ASSIGNS, and which therefore own what
// they hold: retained on entry, enrolled in the body's ARC scope, released on
// every exit. Consumed by lowerBlockStmt when it pushes that outermost scope.
@property(nonatomic) NSMutableArray<NSString*>* pendingStrongParams;
// `defer` bodies registered in each scope, parallel to arcScopeStack — index i
// holds the bodies registered in arcScopeStack[i], in registration order. A
// scope exit runs them LAST-REGISTERED-FIRST and, crucially, BEFORE that scope's
// ARC releases: a defer body exists to use the locals it is cleaning up, so
// `defer { f.close(); }` is meaningless if `f` has already been released.
// See private:docs/Design/exceptions-and-defer.md §4.
@property(nonatomic) NSMutableArray<NSMutableArray<XTASTNode*>*>* deferScopeStack;
// YES while lowering the body of a function declared `throws` — it has the
// hidden `$err` out-parameter, so `throw` has somewhere to store.
@property(nonatomic) BOOL currentFnThrows;
// Bitcast result valueId -> the value it was cast FROM. `return (Base@)local;`
// returns the CAST, whose valueId differs from the local's, so the return-path
// ARC exemption could not match it and released the local while the caller still
// held it — a use-after-free. Consulted by releaseStrongLocalsAlongReturnExcept:.
@property(nonatomic) NSMutableDictionary<NSNumber*, XTIRValue*>* bitcastSource;
// Enclosing `try` handlers, innermost last. Each entry is the catch block a
// raising call inside that `try` must branch to. Empty means a raising call
// propagates instead (which is only legal in a `throws` function).
@property(nonatomic) NSMutableArray<XTIRBlock*>* tryHandlerStack;
// Set of local names whose current value is class-pointer-typed and is
// owned by this scope (strong slot). Used by assignment lowering to
// emit "release old / retain new" pairs.
@property(nonatomic) NSMutableSet<NSString*>* strongLocals;
// Local names that are ARRAYS of class pointers (`Leaf@ arr[N]`). These
// also appear in arcScopeStack, but scope-exit releases each element
// (not the array slot as a single pointer) — keyed to the array type so
// the walker knows the element count + element pointer type.
@property(nonatomic) NSMutableDictionary<NSString*, XTArrayType*>* strongArrayLocals;
// Weak local arrays (`weak:T@ arr[N]`): not owned (no Release), but every
// element slot must be UNREGISTERED from the weak side-table at scope exit, or
// a later array reusing the same stack slots inherits stale entries (weak_array
// T4). Parallels strongArrayLocals; torn down at the same three sites.
@property(nonatomic) NSMutableDictionary<NSString*, XTArrayType*>* weakArrayLocals;
// Struct locals embedding ≥1 strong (or weak) class-pointer field. At scope
// exit the strong fields are Released (weak ones unregistered) — a struct owns
// its embedded class pointers like a class owns its ivars. Torn down at the same
// three sites as strongArrayLocals. Flat struct locals only (nested/array/param
// bases fall back to no-ARC). (arc_struct_copy/walker/large_struct.)
@property(nonatomic) NSMutableDictionary<NSString*, XTStructType*>* strongStructLocals;
// Local ARRAYS whose element is a struct embedding owned class pointers
// (`Holder harr[N]`). Each element is recursively zero-inited + torn down.
@property(nonatomic) NSMutableDictionary<NSString*, XTArrayType*>* strongStructArrayLocals;
// Name of the struct local whose +1 transfers to the caller on the CURRENT
// return (sret move) — its scope-exit teardown is skipped so the returned
// struct's strong fields aren't freed out from under the caller.
@property(nonatomic, copy, nullable) NSString* returnExemptStructName;
// Heap-array element-count tracker: `T@ p = new T[N];` (with N
// foldable to a compile-time integer) records the local name → N so
// `p.length` lowers to a Const without a runtime header read. Reset
// per function in _lowerCallable. Hashes survive only when the local
// isn't reassigned afterwards — sema doesn't reliably know that, so
// it's a best-effort match; on miss the .length access still soft-fails
// and the caller has to use a runtime path. Used for the length_prop
// and array_slice_heap fixtures.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* heapArrayLengthByLocal;
// ARC 2d self-retain: set by the method-lowering callers when the method
// must retain `self` on entry (every call site is a heap receiver, and
// it's an instance method that isn't a destructor). `_lowerCallable`
// consumes `pendingRetainSelf` into `currentRetainedSelf`, which the
// scope-exit teardown releases on every return path.
@property(nonatomic) BOOL pendingRetainSelf;
@property(nonatomic, nullable) XTIRValue* currentRetainedSelf;
// Class names for which a `<Class>$dealloc` was synthesised (the class
// owns strong class-pointer ivars but declared no dealloc) — preScanClass
// registers the function symbol, lowerClass emits its (empty) body so the
// scope-exit teardown releases those ivars.
@property(nonatomic) NSMutableSet<NSString*>* synthDeallocClasses;

// Owned (+1) class temporaries produced in the current full-expression
// and not yet consumed by a strong binding or a return — `new T`
// results and returnsRetained-call results. Released at the end of the
// full-expression (lowerExprStmt / strong-local-decl init / return /
// loop+if conditions), unless the expression created control-flow
// blocks (a ternary/short-circuit arm), in which case they are dropped
// untracked (conservative leak — a conditionally-produced temp must not
// be released unconditionally in the join block).
@property(nonatomic) NSMutableArray<XTIRValue*>* ownedTemps;
// The conditional-nesting depth at which each ownedTemps[i] was created. A
// temp is only safe to release at end-of-full-expression if it was created
// UNCONDITIONALLY relative to that point — i.e. at the same depth. A
// static-init guard branches but immediately rejoins, so it does NOT change
// depth; a ternary / short-circuit ARM does. Parallel to ownedTemps.
@property(nonatomic) NSMutableArray<NSNumber*>* ownedTempDepths;
// The block each ownedTemps[i] was CREATED in. A static call emits its
// init guard first and so splits the block, which left the temp's start
// block no longer equal to currentBlock and the release dropped — the
// variadic case leaked (bug 037). Releasing in the block that defines the
// temp is always safe: it dominates itself. Parallel to ownedTemps.
@property(nonatomic) NSMutableArray* ownedTempBlocks;
// Incremented while lowering a ternary / short-circuit arm, so a `+1` temp born
// on one arm is known to be conditional. Zero at statement level.
@property(nonatomic) NSInteger condDepth;

// Pinned-locals map: name → XTIRPinnedLocal. Populated by the
// pre-scan in `_lowerCallable:` when the function body references
// `&<name>`. Identifier lookups, var-decl init, and assignment
// check this map BEFORE the SSA `locals` map: pinned locals are
// always backed by Load/Store on the slot address.
@property(nonatomic) NSMutableDictionary<NSString*, XTIRPinnedLocal*>* pinnedLocals;
// AST type of each pinned local, so the weak-local register/unregister can tell
// a `weak:T@` from a `^` from an ordinary pinned struct.
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* pinnedLocalASTType;
// Pinned locals that hold a weak side-table entry (`weak:T@` or a `^`). Their
// entry MUST be dropped at scope exit: the frame slot is about to be reused, and
// a stale entry would let a later dealloc write through it.
@property(nonatomic) NSMutableSet<NSString*>* weakPinnedLocals;
// Globals declared `weak:` — their storage is Agg[prev, next, payload], so every
// access must go through globalPayloadAddr:.
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* weakGlobals;
// `@`→`^` widening adapters, keyed on the signature's STRUCTURAL displayName —
// one trampoline per SIGNATURE, not per callee. Deduplication is load-bearing: a
// `^` is compared as a pair, so two `^`s naming the same action must share a code
// word, or `removeAction(&f)` silently misses what `addAction(&f)` stored.
@property(nonatomic) NSMutableDictionary<NSString*, NSString*>* boundTrampolines;

// Re-declared pinned scalars: a block-scoped local name that is `&`/asm-
// named AND declared at more than one distinct type across the function
// body (e.g. `{ u8 c = … } … { u32 c = … }` where both blocks do `LDA c`).
// A single name-keyed slot can only carry one type, so every block but the
// one matching that type mismatches the verifier (§12.2). Instead, give
// such a name one slot per distinct declared type: name → (type displayName
// → pinned local). lowerVarDecl rebinds self.pinnedLocals[name] to the
// matching slot as it enters each declaration, so in-scope reads and the
// asm-name rewrite resolve to a correctly-typed slot. Names declared at a
// single type never appear here and keep their original single-slot layout
// (byte-identical IR). Populated by the pre-scan.
@property(nonatomic) NSMutableDictionary<NSString*,
                                         NSMutableDictionary<NSString*, XTIRPinnedLocal*>*>* pinnedLocalsByType;

// Stack-allocated (value) class instances: local name → its
// XTIRClassInfo. Populated by the pre-scan alongside pinnedLocals — a
// bare `Animal a;` (no `new`) is pinned with an Agg(instanceLayout)
// slot, and the name reads back as the slot ADDRESS (typed
// `ci.selfPtrType`) rather than a Load, so member access / method
// dispatch reuse the unchanged class-POINTER paths. Checked before
// pinnedLocals in identifier lookup; the method-call lowering uses it
// to tell a real instance call (`a.describe()`) from a static call
// (`Stdio.foo()`) when the receiver is a bare class type.
@property(nonatomic) NSMutableDictionary<NSString*, XTIRClassInfo*>* valueClassLocals;

// Names of pinned locals that were declared as ARRAY (not struct).
// Populated by the same pre-scan that fills `pinnedLocals`. A bare
// identifier reference to one of these decays to a pointer-to-
// element (C-style array decay) instead of loading the whole
// aggregate as a value — without this, `Sort.qsort(buf, …)` ends
// up pushing all `sizeof(buf)` bytes into the call's arg frame.
// Struct names stay on the load path so passing/copying a struct
// value through the bare name keeps its existing semantics.
@property(nonatomic) NSMutableSet<NSString*>* arrayLocalNames;
// Map from pinned-array-local name → its AST element type. Used
// by the bare-name decay path to build the element pointer
// (instead of guessing from the IR layout). Populated alongside
// arrayLocalNames.
@property(nonatomic) NSMutableDictionary<NSString*, XTType*>* arrayLocalElementType;

// Transient pre-scan sets populated by collectAddressTakenIn:. The
// address-taken set it returns mixes two distinct sources that need
// opposite treatment: a local whose address is explicitly `&`-taken
// (its pointer escapes — may be dereferenced across a call) versus a
// local merely named in an inline-asm block (which MUST keep a ZP
// address so `STA name` / `(name),Y` resolve). The first set drives
// the pinned-local escapesViaPointer flag; the second excludes asm
// locals from it. Reset at the start of each pre-scan.
@property(nonatomic) NSMutableSet<NSString*>* preScanAmpTakenNames;
@property(nonatomic) NSMutableSet<NSString*>* preScanAsmNamedNames;

// A scalar/pointer PARAMETER whose address is `&`-taken gets its own pinned
// frame slot (not the param SSA value), keyed here to the incoming param value
// that the function prologue must copy into that slot once. Without the copy,
// `AddrOf param` mutates the caller's argument value after inlining — a shared
// argument (e.g. a constant feeding several calls) is then corrupted (bug 202).
// Populated by preScanAddressTakenLocalsIn:, drained at the function entry.
@property(nonatomic) NSMutableDictionary<NSString*, XTIRValue*>* pinnedParamInit;

// Names used as the cursor (first argument) of a va_start / va_arg_<T>
// intrinsic. Collected by collectAddressTakenIn: and pinned to a frame
// slot by the pre-scan so the cursor's loop-carried offset flows through
// the Mem token instead of SSA phis — a plain SSA local gets cross-wired
// with sibling locals by the loop/if phi builder, leaving every va_arg
// stuck reading buffer offset 0 (task #120). Reset at each pre-scan.
@property(nonatomic) NSMutableSet<NSString*>* preScanVarargCursorNames;

// Struct-layout cache: structName → XTIRLayout. Lazily built when
// the lowering first encounters a struct type. Mirrors the per-class
// `instanceLayout` machinery, minus the vtable slot at field 0. The
// layout is added to the module's layout table on creation so the
// printer / verifier can reference it by index.
@property(nonatomic) NSMutableDictionary<NSString*, XTIRLayout*>* structLayouts;

// Module-level globals: name → symbol-id of the DataGlobal symbol
// registered in self.module. Populated by the top-level VariableDecl
// pre-scan and read by identifier / assign / AddrOf lowering. A name
// in this map shadows nothing — locals / pinned / ivars are checked
// first.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* globalsByName;
// Function-local `static` variables are backed by persistent module
// globals (registered in globalsByName under the local name so reads/
// writes route through the global Load/Store paths). This map records,
// per declaring function, the globalsByName entry the static SHADOWED
// (NSNull if the name was free) so the binding can be restored when the
// next function is lowered — a static's storage is module-wide but its
// NAME scope is the declaring function.
@property(nonatomic) NSMutableDictionary<NSString*, id>* staticLocalSaved;
// Enum constant name → integer value (e.g. `red` → 0). Resolved as a
// compile-time Const when referenced as an identifier or case label.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* enumConstants;

// String-literal interning: byte-content (NSData) → symbol-id of the
// StringLit symbol. Deduplicates identical literals so they share one
// symbol. Keyed on the NUL-terminated bytes.
@property(nonatomic) NSMutableDictionary<NSData*, NSNumber*>* stringLiterals;
// -fbounds-check: emit a runtime bounds check at every subscript.
@property(nonatomic) BOOL boundsCheck;
// Globals whose initialiser could not constant-fold (a string literal is an
// ADDRESS; a float leaf; an expression). Lowered as ordinary stores at the
// top of main instead of silently reading back zeros; a module with no main
// gets the old warning, at end of lowering, for each leftover.
@property(nonatomic) NSMutableArray<XTVariableDeclNode*>* pendingGlobalInits;

// Per-class static-data block: className → symbol-id of the
// `__sdata_<Class>` DataGlobal (sized to the instance layout, zeroed).
// A static method's `self` is the address of this block, so the
// ordinary ivar FieldAddr machinery reaches the class's fields.
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* staticDataByClass;
// `__sinit_<Class>` once-guard flag globals (u8, zeroed), keyed by class
// name. A static method call to a class with an `init` runs `init` once
// per program via this flag (mirrors the legacy codegen's static-init
// guard); without it the static `__sdata` block stays zeroed (e.g.
// Stdio's `canPrint` == 0 → printf silently no-ops).
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* staticInitFlagByClass;
// Set transiently while lowering a static method body so _lowerCallable
// binds currentSelf to AddrOf(__sdata_<Class>).
@property(nonatomic, nullable, copy) NSString* staticSelfClassName;
// Set transiently before lowering an `init` method whose body omits an
// explicit `super.init()` and whose sema-set `autoSuperInit` flag asks
// the compiler to inject a parent-first `super.init()` at the top of the
// body. Holds the parent's no-arg init symbol name; _lowerCallable emits
// the call after binding `self` and clears it. (private:docs/bugs/011 #1)
@property(nonatomic, nullable, copy) NSString* pendingAutoSuperInitTarget;
// This module gets the race-free static-init once (§9.5). Decided once in
// lowerProgram, read by emitStaticInitGuardForClass:.
@property(nonatomic) BOOL threadSafeStatics;
@end

static BOOL sItableProtocols = NO;

// Conformance itable WITHOUT itable dispatch: build the per-class (protoId, &table)
// itable and reserve its vtable slot so a runtime `(P@ ?)obj` conformance downcast
// can search the protocol ids — but keep dispatch on the flat vtable slots. ON for
// the flat cross-`.so` backends (arm64/x86_64/win64); arm9 gets the same itable
// through sItableProtocols (which ALSO routes dispatch through it), and xt6502/m68k
// use the compile-time conforming-set downcast. The itable slot exists whenever
// `sItableProtocols || sVtableConforms`.
static BOOL sVtableConforms = NO;

// Runtime-ancestry vtables: a parent-vtable link at vtable entry 0 + the `as?`/`as`
// downcast walking it, so a subclass defined in ANOTHER module is recognised as its
// base. ON for the cross-`.so` backends (arm9/arm64/x86_64/win64). OFF for xt6502
// (banked 3-byte pointers) and m68k, which do not link separate shared objects —
// they keep the compile-time-subtree downcast and a parent-free vtable (byte-identical
// old codegen). Default ON so the target-agnostic front-end tests exercise the walk.
static BOOL sVtableAncestry = YES;

/****************************************************************************\
|* How many HEADER words sit in front of a vtable's method slots.
|*
|*   [0] parent link       ancestry walk (`as?` across a .so)
|*   [1] itable pointer    protocol conformance
|*   [2] category chain    §4.2 — a category on a class from a prebuilt .so
|*   [3..] methods
|*
|* Entry 0 and entry 1 are read by NAME elsewhere (the downcast walker; the
|* injected `_xtc_obj_conforms`, which indexes vtbl[1]), so the chain word goes
|* AFTER them and only the method base moves. Every dispatch site adds this,
|* and only emitVTblDispatch / emitVTblLoad do, so methodSlot and
|* resolvedVirtualSlot stay 0-based everywhere else.
|*
|* The chain word rides sVtableAncestry: it is needed exactly where a class can
|* be extended by a module compiled later (the cross-`.so` backends), and the
|* single-module targets (xt6502/m68k) merge a category at compile time and pay
|* nothing. It must be reserved in EVERY vtable on those targets, including a
|* library's own — a client reading it off a library-built receiver would
|* otherwise read that class's first method pointer and treat it as a chain.
\****************************************************************************/
static NSUInteger XTVtblHeaderWords(void)
    {
    return (sVtableAncestry ? 1 : 0)                         // parent
           + ((sItableProtocols || sVtableConforms) ? 1 : 0) // itable
           + (sVtableAncestry ? 1 : 0);                      // category chain
    }

// Index of the category-chain word: the last header word, so it exists only
// where sVtableAncestry does.
static NSUInteger XTVtblCatChainIndex(void)
    {
    return XTVtblHeaderWords() - 1;
    }

// The bounded C-variadic rule (blewit item 2): a BODY-LESS declaration
// ending in `...` names a C callee — there is no xtc body that could walk a
// pack buffer, and every actual argument's type is static at the call site.
// So such a call is C-ABI: the existing cabi machinery default-promotes the
// tail and passes it natively, exactly as a DWARF-imported printf is called.
// An xtc-BODIED variadic keeps the pack-buffer convention untouched.
static BOOL XTFnIsCABI(XTFunctionDeclNode* fn)
    {
    return fn.isCImport || (fn.isVarArgs && fn.body == nil);
    }

// Race-free static-init once (private:docs/Design/threading.md §9.5). -1 = decide per
// module (the default), 0/1 = forced by -fno-thread-safe-arc / -fthread-safe-arc.
//
// Gated for the same reason atomic ARC is: only a program that can have two
// threads reach one class's FIRST static use needs the once, and a program that
// cannot should pay nothing — not the two runtime calls, and not a changed
// instruction stream. Ungated this would re-baseline every differential and tax
// xt6502/m68k for a race those targets cannot have.
static int sThreadSafeStatics = -1;

// Does this program declare the thread-spawn primitive? `Thread.xc` declares
// `pointer _xt_thread_create(pointer, pointer);` at FILE SCOPE, so the answer is
// a scan of the top-level declarations — no walk into bodies.
//
// Deliberately conservative: importing Thread.xc without ever calling `spawn`
// turns this on, because the prototype is there whether or not the call
// survives. The back ends decide atomic ARC from the post-DFE instruction
// stream, so that case gets the safe once with plain refcounts. Erring this way
// costs a program that imports-but-never-threads two calls per static-init site;
// erring the other way costs correctness.
static BOOL XTProgramDeclaresThreadCreate(XTProgramNode* program)
    {
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind != XTASTNodeKindFunctionDecl)
            continue;
        if ([((XTFunctionDeclNode*)decl).funcName isEqualToString:@"_xt_thread_create"])
            return YES;
        }
    return NO;
    }

@implementation XTIRLowering

+ (void)setItableProtocols:(BOOL)on
    {
    sItableProtocols = on;
    }
+ (BOOL)itableProtocols
    {
    return sItableProtocols;
    }

+ (void)setThreadSafeStatics:(int)mode
    {
    sThreadSafeStatics = mode;
    }
+ (int)threadSafeStatics
    {
    return sThreadSafeStatics;
    }

+ (void)setVtableConforms:(BOOL)on
    {
    sVtableConforms = on;
    }
+ (BOOL)vtableConforms
    {
    return sVtableConforms;
    }

+ (void)setVtableAncestry:(BOOL)on
    {
    sVtableAncestry = on;
    }
+ (BOOL)vtableAncestry
    {
    return sVtableAncestry;
    }

/****************************************************************************\
|* A protocol's identity, as a VALUE: FNV-1a 32 of its name.
|*
|* Not an address. The loader binds a defined symbol to the module that defines
|* it, with no interposition (see bound-methods-across-modules.md), so an
|* address-based id would differ per module — the exact mistake that made the `^`
|* trampoline guard write into .text. A hash of the name is derived identically by
|* every module with zero coordination, which is the whole point.
\****************************************************************************/
static uint32_t xtProtocolId(NSString* name)
    {
    uint32_t h = 2166136261u;
    const char* p = name.UTF8String;
    while (*p)
        {
        h ^= (uint8_t)*p++;
        h *= 16777619u;
        }
    return h ?: 1u; // 0 terminates the itable — never an id
    }

#pragma mark - Type mapping

- (nullable XTIRType*)irTypeForASTType:(XTType*)ty at:(XTSourceLocation*)loc
    {
    if (!ty)
        return nil;
    switch (ty.kind)
        {
    case XTTypeKindI8:
        return [XTIRType i8Type];
    case XTTypeKindU8:
        return [XTIRType u8Type];
    case XTTypeKindI16:
        return [XTIRType i16Type];
    case XTTypeKindU16:
        return [XTIRType u16Type];
    case XTTypeKindI32:
        return [XTIRType i32Type];
    case XTTypeKindU32:
        return [XTIRType u32Type];
    case XTTypeKindI64:
        return [XTIRType i64Type];
    case XTTypeKindU64:
        return [XTIRType u64Type];
    case XTTypeKindBool:
        return [XTIRType boolType];
    case XTTypeKindVoid:
        return [XTIRType voidType];
    case XTTypeKindFloat:
        return [XTIRType f32Type]; // single-precision (backend owns width)
    case XTTypeKindDouble:
        return [XTIRType f64Type]; // double-precision
    case XTTypeKindPointer:
        {
        // Class-pointer → Ptr(Agg(instanceLayout), unbanked).
        // Other pointers → Ptr(<pointee-or-Void>, unbanked). The
        // bare `XTType pointerType` (no pointee info) reports
        // `kind == XTTypeKindPointer` without being an
        // XTPointerType subclass, so guard the cast.
        XTType* pointee = nil;
        if ([ty isKindOfClass:[XTPointerType class]])
            {
            pointee = ((XTPointerType*)ty).pointeeType;
            }
        if (pointee && pointee.kind == XTTypeKindClass)
            {
            XTIRClassInfo* ci = [self classInfoResolvingName:pointee.displayName];
            if (ci)
                return ci.selfPtrType;
            }
        XTIRType* inner = nil;
        if (pointee)
            {
            switch (pointee.kind)
                {
            case XTTypeKindI8:
                inner = [XTIRType i8Type];
                break;
            case XTTypeKindU8:
                inner = [XTIRType u8Type];
                break;
            case XTTypeKindI16:
                inner = [XTIRType i16Type];
                break;
            case XTTypeKindU16:
                inner = [XTIRType u16Type];
                break;
            case XTTypeKindI32:
                inner = [XTIRType i32Type];
                break;
            case XTTypeKindU32:
                inner = [XTIRType u32Type];
                break;
            case XTTypeKindI64:
                inner = [XTIRType i64Type];
                break;
            case XTTypeKindU64:
                inner = [XTIRType u64Type];
                break;
            // float / double pointees: without these the pointee
            // collapsed to Ptr(Void), so ElementAddr scaled a
            // `float@`/`double@` subscript by sizeof(Void)=1 — array
            // elements overlapped and only the last write survived
            // (subscript_float, both backends). private:docs/bugs/011 #2.
            case XTTypeKindFloat:
                inner = [XTIRType f32Type];
                break;
            case XTTypeKindDouble:
                inner = [XTIRType f64Type];
                break;
            case XTTypeKindBool:
                inner = [XTIRType boolType];
                break;
            case XTTypeKindVoid:
                inner = [XTIRType voidType];
                break;
            case XTTypeKindPointer:
                {
                // Pointer-to-pointer (e.g. `pointer@`): the element
                // is itself a pointer, so the inner type must be a
                // Ptr — NOT Void. If it collapses to Ptr(Void),
                // ElementAddr scales the subscript index by
                // sizeof(Void)=1, so `b[i]` on a pointer array
                // lands at the wrong byte (a 6502 2-byte load stays
                // in-bounds and limps along; an arm64 8-byte load
                // reads out of bounds → garbage pointer → segfault).
                // Recurse so the element carries the pointer's own
                // backend width (xt6502 2 / arm64 8).
                inner = [self irTypeForASTTypeQuiet:pointee] ?: [XTIRType voidType];
                break;
                }
            case XTTypeKindStruct:
            case XTTypeKindArray:
                {
                // Pointer to a struct/array: carry the aggregate
                // layout through so FieldAddr / ElementAddr can
                // read field byte-offsets and element strides from
                // the pointee. Without this it collapsed to
                // Ptr(Void), and FieldAddr (which derives the
                // offset from the base's pointee layout) defaulted
                // every offset to 0 — so `p->a.b` through a struct
                // pointer landed back at the base (the small_struct
                // pointer-base returns read garbage). Recurse so the
                // pointee picks up its Agg(layout).
                inner = [self irTypeForASTTypeQuiet:pointee] ?: [XTIRType voidType];
                break;
                }
            default:
                inner = [XTIRType voidType];
                break;
                }
            }
        else
            {
            inner = [XTIRType voidType];
            }
        return [XTIRType ptrToType:inner window:XTIRWindowUnbanked];
        }
    case XTTypeKindClass:
        {
        // A bare class type reference (used as a marker) — surface
        // as the class's instance-pointer type. Sema typically wraps
        // class types in a pointer, so we rarely hit this directly,
        // but keep the path for completeness.
        XTIRClassInfo* ci = [self classInfoResolvingName:ty.displayName];
        if (ci)
            return ci.selfPtrType;
        // Fall through to the soft-fail diagnostic.
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unknown class type '%@'", ty.displayName]];
        return nil;
        }
    case XTTypeKindStruct:
        {
        if (![ty isKindOfClass:[XTStructType class]])
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: struct marker '%@' has no fields", ty.displayName]];
            return nil;
            }
        XTIRLayout* L = [self layoutForStructType:(XTStructType*)ty];
        if (!L)
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: struct '%@' contains an unsupported field type",
                                                   ty.displayName]];
            return nil;
            }
        return [XTIRType aggWithLayout:L];
        }
    case XTTypeKindArray:
        {
        if (![ty isKindOfClass:[XTArrayType class]])
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: array type '%@' has no element info", ty.displayName]];
            return nil;
            }
        XTIRLayout* L = [self layoutForArrayType:(XTArrayType*)ty];
        if (!L)
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: array '%@' has an unsupported element type",
                                                   ty.displayName]];
            return nil;
            }
        return [XTIRType aggWithLayout:L];
        }
    case XTTypeKindEnum:
        {
        // Lower an enum as its declared underlying integer type — the
        // smallest int that fits all member values, chosen by sema.
        // Enum values participate in arithmetic / comparison / printf
        // through the underlying scalar.
        if ([ty isKindOfClass:[XTEnumType class]])
            {
            XTType* under = ((XTEnumType*)ty).underlyingType;
            if (under)
                return [self irTypeForASTType:under at:loc];
            }
        // Unresolved enum marker — fall through to the soft-fail.
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: enum '%@' has no underlying type", ty.displayName]];
        return nil;
        }
    default:
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unsupported type '%@' (kind %ld)",
                                               ty.displayName, (long)ty.kind]];
        return nil;
        }
    }

// Best-effort variant: returns nil for unsupported types without
// touching the diagnostic engine. Used by pre-scan paths that want to
// skip a single declaration cleanly (e.g. a method whose float
// parameter we can't lower yet) without polluting the module-level
// diagnostic state.
- (nullable XTIRType*)irTypeForASTTypeQuiet:(XTType*)ty
    {
    if (!ty)
        return nil;
    XTDiagnosticEngine* saved = self.diag;
    self.diag = nil;
    BOOL savedAborted = self.aborted;
    // Nothing in the IR or type layers raises, so this needed no exception
    // handler — the "quiet" part is the suppressed diagnostics either side, not
    // a caught throw. (xtc has no exceptions; see exceptions-and-defer.md E3.)
    XTIRType* result = [self irTypeForASTType:ty at:nil];
    self.diag = saved;
    self.aborted = savedAborted;
    return result;
    }

// Returns YES if `ty` is a pointer-to-class — the predicate that
// distinguishes a strong-slot heap reference from a plain integer or
// non-class pointer. Used by ARC scope tracking and assignment lowering.
// Per-function soft-fail. Emits a note (which doesn't set the
// diagnostic engine's hasFatalError flag) and marks the current
// function lowering aborted. The enclosing `_lowerCallable:` notices
// the aborted flag and resets the function's body to a single
// Unreachable-terminated entry block. The module overall stays
// well-formed; fixtures land at the next pipeline stage (verifier or
// backend) with a more specific reason — which is exactly what the
// new-IR progress report wants.
- (void)softFailLoweringAt:(nullable XTSourceLocation*)loc
               withMessage:(NSString*)message
    {
    // An ERROR, not a note.
    //
    // This ABANDONS the function — it emits no code for it at all. As a note, the
    // build then SUCCEEDED and the program silently did nothing where that function
    // should have run: `&caret` handed a garbage pointer to objc_edit, `o.ob_spec =
    // (pointer)&ted` carried junk, and nothing said so. That is the fifth instance of
    // one habit (Gap C, Gap E, Gap F, the imported-struct param, and this), and the
    // habit is what costs the debugging session — see
    // private:docs/Design/no-silent-degradation.md.
    //
    // If the lowering cannot express something, that is an unimplemented FEATURE, and
    // an unimplemented feature costs an hour. Emitting nothing and claiming success
    // costs trust in every other answer the compiler gives.
    //
    // The `ABANDON|` marker stays: the corpus harness tallies these by category into
    // doc/abandon-reasons.*.txt, and that tally is how the remaining gaps get found.
    [self.diag emitError:[@"ABANDON|" stringByAppendingString:message] at:loc];
    self.aborted = YES;
    }

// Lazily build (and cache) the XTIRLayout for `struct`. Field offsets
// come straight from the parser-computed XTStructField.byteOffset;
// the IR type per field is irTypeForASTTypeQuiet:. Layout is also
// added to the module's layoutTable so the printer / verifier can
// reference it by index. Structs differ from classes in that there
// is no vtable pointer at field 0 — fields are 1:1 with source.
- (nullable XTIRLayout*)layoutForStructType:(XTStructType*)st
    {
    if (!st)
        return nil;
    NSString* key = st.structName ?: [NSString stringWithFormat:@"<anon-%p>", (void*)st];
    XTIRLayout* cached = self.structLayouts[key];
    if (cached)
        return cached;

    // Pre-cache an EMPTY layout before resolving fields. A self-referential
    // struct (`struct node { node@ next; }`) has a field that is a pointer
    // back to itself; resolving that field re-enters this method for the same
    // struct. Caching the object first makes the re-entry return THIS object
    // instead of recursing forever — then we fill it in place so the captured
    // `Ptr(Agg(self))` references the completed layout. An Agg type holds the
    // layout OBJECT (its table index is resolved at print time), so we add to
    // the module table only on SUCCESS, after filling — preserving the
    // original table order and never leaving an orphan on a field failure.
    // Common in imported C structs (linked lists, FILE); the corpus's own
    // structs never recursed, so this path was latent until library imports.
    XTIRLayout* L = [[XTIRLayout alloc] initWithSize:0 alignment:1 fields:@[]];
    self.structLayouts[key] = L;

    NSMutableArray<XTIRLayoutField*>* fields = [NSMutableArray array];
    uint32_t size = 0;
    for (XTStructField* f in st.fields)
        {
        XTIRType* fIR = [self irTypeForASTTypeQuiet:f.fieldType];
        if (!fIR)
            {
            // Genuinely unsupported field — drop the placeholder so a later
            // lookup doesn't see a bogus empty layout (never added to the
            // module table, so nothing else references it).
            [self.structLayouts removeObjectForKey:key];
            return nil;
            }
        // An auto-zeroing field carries two hidden LINK words before its payload.
        // They are REAL fields (with recorded offsets, immediately before the
        // payload — XTLayoutStructFields aligns the payload so the links stay
        // contiguous), because the runtime addresses slot[-1]/slot[-2] and the
        // field indices must account for them.
        // structType:fieldNamed:index: maps a source field to its IR index.
        if ([self astTypeIsWeakSlot:f.fieldType])
            {
            uint32_t lw = (uint32_t)[XTPointerType pointerToType:[XTType u8Type]].byteWidth;
            XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                            window:XTIRWindowUnbanked];
            [fields addObject:[[XTIRLayoutField alloc]
                                  initWithOffset:(uint32_t)(f.byteOffset - 2 * lw)
                                            type:linkTy]];
            [fields addObject:[[XTIRLayoutField alloc]
                                  initWithOffset:(uint32_t)(f.byteOffset - lw)
                                            type:linkTy]];
            }
        [fields addObject:[[XTIRLayoutField alloc]
                              initWithOffset:(uint32_t)f.byteOffset
                                        type:fIR]];
        uint32_t fend = (uint32_t)(f.byteOffset + f.fieldType.byteWidth);
        if (fend > size)
            size = fend;
        }
    // Round the layout size up to the struct's C alignment (bug 015): `byteWidth`
    // includes the trailing pad, so sizeof, struct copies, by-value passing, and
    // array strides all agree with C and across every backend (the native aggSize
    // helpers floor at this layout.size; xt6502 reads it directly).
    if ((uint32_t)st.byteWidth > size)
        size = (uint32_t)st.byteWidth;
    [L fillWithSize:size fields:fields];
    [self.module addLayout:L];
    return L;
    }

// Build (and cache) the XTIRLayout for an array type: `elementCount`
// fields of the element IR type, packed at `i * elementWidth`. This is
// the array's STORAGE type (so a local/global/ivar array is sized
// correctly); subscripting decays to a Ptr(element) and scales via
// ElementAddr, so it doesn't read this layout's per-field info.
- (nullable XTIRLayout*)layoutForArrayType:(XTArrayType*)at
    {
    if (!at || !at.elementType)
        return nil;
    XTIRType* elemIR = [self irTypeForASTTypeQuiet:at.elementType];
    if (!elemIR)
        return nil;
    uint32_t elemW = (uint32_t)at.elementType.byteWidth;
    // `weak:T@ arr[N]` — EVERY ELEMENT is a weak slot and needs its own link
    // words. Widening the ELEMENT type is all it takes: the array's storage and
    // ElementAddr's stride are both derived from it, so they grow together and
    // stay consistent by construction. Without this the runtime would write
    // slot[-1]/slot[-2] over the PREVIOUS ELEMENT.
    // The payload is reached via field 2 — see elementPayloadAddr:.
    BOOL weakElem = [self astTypeIsWeakSlot:at.elementType];
    if (weakElem)
        {
        elemIR = [self weakSlotAggFor:elemIR];
        elemW += 2 * (uint32_t)[XTPointerType pointerToType:[XTType u8Type]].byteWidth;
        }
    NSString* key = [NSString stringWithFormat:@"[]%@%@x%lu",
                                               (weakElem ? @"weak:" : @""),
                                               at.elementType.displayName, (unsigned long)at.elementCount];
    XTIRLayout* cached = self.structLayouts[key];
    if (cached)
        return cached;

    NSMutableArray<XTIRLayoutField*>* fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < at.elementCount; i++)
        {
        [fields addObject:[[XTIRLayoutField alloc]
                              initWithOffset:(uint32_t)(i * elemW)
                                        type:elemIR]];
        }
    XTIRLayout* L = [[XTIRLayout alloc] initWithSize:(uint32_t)(elemW * at.elementCount)
                                           alignment:1
                                              fields:fields];
    [self.module addLayout:L];
    self.structLayouts[key] = L;
    return L;
    }

// Build a synthetic aggregate layout from an array of AST return types
// (for multi-return functions). Fields follow the same (capped) natural
// alignment rule as struct fields — the tuple is a real in-memory buffer
// on the sret path, so its slots align like any other aggregate's. The
// cache key is a global counter because these are anonymous tuples, not
// named types.
- (nullable XTIRLayout*)layoutForTupleReturnTypes:(NSArray<XTType*>*)types
    {
    if (types.count == 0)
        return nil;
    NSMutableArray<XTIRLayoutField*>* fields = [NSMutableArray array];
    uint32_t offset = 0;
    for (NSUInteger i = 0; i < types.count; i++)
        {
        XTType* astTy = types[i];
        XTIRType* fIR = [self irTypeForASTTypeQuiet:astTy];
        if (!fIR)
            return nil;
        uint32_t fa = (uint32_t)[XTStructType fieldAlignmentForType:astTy];
        offset = (offset + fa - 1) & ~(fa - 1);
        [fields addObject:[[XTIRLayoutField alloc]
                              initWithOffset:offset
                                        type:fIR]];
        offset += (uint32_t)astTy.byteWidth;
        }
    static NSUInteger tupleLayoutCounter = 0;
    NSString* key = [NSString stringWithFormat:@"<tuple-%lu>",
                                               (unsigned long)tupleLayoutCounter++];
    XTIRLayout* L = [[XTIRLayout alloc] initWithSize:offset alignment:1 fields:fields];
    [self.module addLayout:L];
    self.structLayouts[key] = L;
    return L;
    }

// Look up a field by name in an XTStructType, returning the field's
// index (matching XTIRLayout.fields ordering) and AST type via
// out-parameters. Returns NO if the field isn't found.
- (BOOL)structType:(XTStructType*)st
        fieldNamed:(NSString*)name
             index:(NSUInteger*)outIndex
           astType:(XTType* _Nullable* _Nullable)outType
    {
    NSUInteger i = 0;
    for (XTStructField* f in st.fields)
        {
        // An auto-zeroing field is preceded by two hidden LINK fields in the IR
        // layout, so the source field's index is NOT its position in st.fields.
        if ([self astTypeIsWeakSlot:f.fieldType])
            i += 2;
        if ([f.fieldName isEqualToString:name])
            {
            if (outIndex)
                *outIndex = i;
            if (outType)
                *outType = f.fieldType;
            return YES;
            }
        i++;
        }
    return NO;
    }

// A class pointer, WEAK OR STRONG. The predicate above deliberately says NO to
// a weak pointer, because a weak SLOT is not ARC-tracked storage — it must not
// be retained or released as one. But a weak VALUE read out of such a slot and
// bound into a STRONG destination is a different question, and the answer is
// the one ObjC ARC gives: the destination takes ownership, so it retains.
//
// Getting that backwards is a use-after-free, not a leak. `T@ v = h.owner;`
// (owner weak) emitted no retain because the SOURCE type was weak, and then
// released `v` at scope exit because the DESTINATION was strong — a net -1 on
// every call, so an object with one real owner died on the first read. XG's
// AppKit tree-draw path is exactly that shape and freed the window's view tree
// during the first draw (bug 019).
- (BOOL)astTypeIsAnyClassPointer:(nullable XTType*)ty
    {
    if (!ty)
        return NO;
    if (![ty isKindOfClass:[XTPointerType class]])
        return NO;
    XTType* pointee = ((XTPointerType*)ty).pointeeType;
    return pointee && pointee.kind == XTTypeKindClass;
    }

- (BOOL)astTypeIsClassPointer:(nullable XTType*)ty
    {
    if (!ty)
        return NO;
    if (![ty isKindOfClass:[XTPointerType class]])
        return NO;
    XTPointerType* pt = (XTPointerType*)ty;
    if (pt.isWeak)
        return NO;
    XTType* pointee = pt.pointeeType;
    return pointee && pointee.kind == XTTypeKindClass;
    }

// YES if `ci` (or any ancestor) declares a strong class-pointer ivar, OR an
// auto-zeroing (weak / callback) one.
// Gates the heap-`new` zero-init: such classes have a first member-store whose
// ARC release-old can free a stale pointer left in a reused heap slot, so they
// need the extra zeroing.
//
// The auto-zeroing half was missing, so a class whose only ivar is a `weak:` or
// `callback` slot got NO zero-init at all — and its two hidden LINK words are
// exactly the thing that must not hold a previous tenant's values. The first
// unregister then follows a garbage `pprev` and writes through it, corrupting a
// chain belonging to some other live object. It needs a `new` in a loop to show
// at all (a fresh page reads as zero), which is why it survived every fixture
// and killed uxkit's undo stack (bug 110 / uxkit 034-B). The shipped compiler
// was fixed there; this is the reference's half of the same rule.
- (BOOL)classHasStrongPointerIvar:(nullable XTIRClassInfo*)ci
    {
    for (XTIRClassInfo* c = ci; c != nil; c = c.parent)
        {
        for (NSString* ivarName in c.ivarFieldIndex)
            {
            if ([self astTypeIsClassPointer:c.ivarASTType[ivarName]])
                return YES;
            if ([self astTypeIsWeakSlot:c.ivarASTType[ivarName]])
                return YES;
            }
        }
    return NO;
    }

// YES if the AST subtree contains an explicit `super.dealloc(...)` call.
// The dealloc teardown auto-appends a super-chain call only when the
// user body does NOT already chain (so Dog.dealloc's explicit
// super.dealloc() isn't doubled). Walks the statement containers a
// dealloc body realistically uses.
- (BOOL)astCallsSuperDealloc:(nullable XTASTNode*)node
    {
    if (!node)
        return NO;
    if (node.nodeKind == XTASTNodeKindMethodCallExpr)
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)node;
        if ([m.receiver isKindOfClass:[XTIdentifierNode class]] && [((XTIdentifierNode*)m.receiver).identName isEqualToString:@"super"] && [m.methodName isEqualToString:@"dealloc"])
            return YES;
        }
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            if ([self astCallsSuperDealloc:s])
                return YES;
        return NO;
    case XTASTNodeKindExprStatement:
        return [self astCallsSuperDealloc:((XTExpressionStatementNode*)node).expression];
    case XTASTNodeKindIf:
        {
        XTIfNode* f = (XTIfNode*)node;
        return [self astCallsSuperDealloc:f.thenBlock] || [self astCallsSuperDealloc:f.elseBlock];
        }
    case XTASTNodeKindWhile:
        return [self astCallsSuperDealloc:((XTWhileNode*)node).body];
    default:
        return NO;
        }
    }

#pragma mark - Insn emission helpers

- (XTIRValue*)allocateValueOfType:(XTIRType*)type atSite:(XTIRBlock*)block
    {
    XTIRValueId vid = [self.currentFunction allocateValueId];
    NSUInteger idx = (block == self.currentBlock) ? self.currentBlock.instructions.count : 0;
    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:block insnIndex:idx];
    XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid type:type defSite:site];
    [self.currentFunction registerValue:v];
    return v;
    }

- (XTIRValue*)emitInsnOpcode:(XTIROpcode)op
                      result:(XTIRType*)resultType
                    operands:(NSArray<XTIROperand*>*)operands
    {
    XTIRValue* r = nil;
    if (resultType.kind != XTIRTypeKindVoid)
        {
        r = [self allocateValueOfType:resultType atSite:self.currentBlock];
        }
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:op
                                               result:r
                                             operands:operands
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

// C default argument promotion for the variadic tail of a C-ABI call (printf):
// a `float` is promoted to `double` (libc's `%f` always reads a double) and a
// sub-`int` integer to `int`. The first `fixed` args are declared params and
// pass through untouched. (xtc-authored variadics don't need this — they pack
// into __xtc_va_buf and read back the exact widths.)
- (NSArray<XTIRValue*>*)cVarargPromote:(NSArray<XTIRValue*>*)args
                            fixedCount:(NSUInteger)fixed
    {
    NSMutableArray<XTIRValue*>* out = [NSMutableArray array];
    for (NSUInteger i = 0; i < args.count; i++)
        {
        XTIRValue* v = args[i];
        if (i < fixed || !v.type)
            {
            [out addObject:v];
            continue;
            }
        XTIRTypeKind k = v.type.kind;
        if (XTIRTypeKindIsFloating(k) && v.type.byteWidth < 8)
            {
            v = [self emitInsnOpcode:XTIROpFpExt
                              result:[XTIRType f64Type]
                            operands:@[ [XTIROperand useWithValueId:v.valueId] ]];
            }
        else if (XTIRTypeKindIsInteger(k) && v.type.byteWidth < 4)
            {
            XTIROpcode ext = XTIRTypeKindIsSigned(k) ? XTIROpSExt : XTIROpZExt;
            v = [self emitInsnOpcode:ext
                              result:[XTIRType i32Type]
                            operands:@[ [XTIROperand useWithValueId:v.valueId] ]];
            }
        [out addObject:v];
        }
    return out;
    }

- (void)emitTerminator:(XTIROpcode)op operands:(NSArray<XTIROperand*>*)operands
    {
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:op
                                               result:nil
                                             operands:operands
                                               dbgLoc:nil];
    [self.currentBlock setTerminator:insn];
    }

/****************************************************************************\
|* The adapter trampoline that lets a plain function pointer stand in for a
|* bound method (`@` → `^` widening).
|*
|* A `^`'s code word is always invoked as `code(recv, args…)`, but a free
|* function has no `self` parameter. Rather than branch on `recv` at every call
|* site (which doubles the call sequence — and on xt6502 the arg marshalling
|* differs, because `self` is pushed LAST), a widened `^` carries
|*
|*     recv = the function pointer
|*     code = this trampoline
|*
|* and the trampoline forwards:
|*
|*     <ret> __bm_tramp_<sig>(pointer fnptr, args…) {
|*         return ((sig@)fnptr)(args…);          // CallIndirect
|*     }
|*
|* ONE per SIGNATURE, not one per callee. That matters twice:
|*
|*  - a per-callee thunk cannot widen a RUNTIME function pointer
|*    (`act_t@ f = &g; act_t^ a = f;`) — the callee isn't known at the widening
|*    site. Carrying the pointer in `recv` handles static and dynamic alike.
|*  - IDENTITY. A `^` is compared as a pair, so two `^`s naming the same action
|*    must be equal, or `removeAction(&f)` silently fails to find what
|*    `addAction(&f)` stored. Here both words match by construction: same
|*    function → same `recv`; same signature → same `code`.
|*
|* NOTE the receiver is NOT owned (see private:docs/Design/bound-methods.md): for a
|* widened function `recv` is a CODE address, and retaining it would refcount
|* .text. A `^` never owns its recv.
\****************************************************************************/
- (nullable NSString*)boundTrampolineForSignature:(XTFunctionType*)sig
    {
    // A `^` is ALWAYS a fixed-arity pair: the trampoline forwards the fixed
    // params (varargs are never materialised — the loop below reads only
    // paramTypes and the symbol is marked variadic:NO), and the bound TYPE that
    // names it is never variadic (a variadic callback field erases to its
    // non-variadic prefix — bug 165b). But the SOURCE can be a variadic
    // function (`&emit` where `void emit(u8*, ...)`), and its `,...` was reaching
    // the trampoline NAME through the display name — so `act_t^ a = &variadicFn`
    // and `act_t^ b = &plainFn` got DIFFERENT code words and compared unequal
    // though both are `act_t^`, and the self-hosted compiler (which keys on the
    // bound type, non-variadic) diverged (bug 165c). Normalise the varargs away.
    if (sig.isVarArgs)
        {
        sig = [XTFunctionType functionWithReturnTypes:sig.returnTypes
                                           paramTypes:sig.paramTypes
                                            isVarArgs:NO];
        }
    NSString* key = sig.displayName;
    NSString* cached = self.boundTrampolines[key];
    if (cached)
        return cached;

    NSMutableString* san = [NSMutableString string];
    for (NSUInteger i = 0; i < key.length; i++)
        {
        unichar c = [key characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        [san appendString:(ok ? [NSString stringWithCharacters:&c length:1] : @"_")];
        }
    NSString* tname = [NSString stringWithFormat:@"__bm_tramp_%@", san];

    XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                  window:XTIRWindowUnbanked];
    XTIRType* retT = nil;
    XTType* astRet = sig.returnTypes.firstObject;
    if (astRet && !astRet.isVoid)
        {
        retT = [self irTypeForASTTypeQuiet:astRet];
        if (!retT)
            return nil;
        }
    NSMutableArray<XTIRType*>* pts = [NSMutableArray arrayWithObject:ptrT];
    for (XTType* pt in sig.paramTypes)
        {
        XTIRType* t = [self irTypeForASTTypeQuiet:pt];
        if (!t)
            return nil;
        [pts addObject:t];
        }
    [pts addObject:[XTIRType memoryType]];

    XTIRBlock* entry = [[XTIRBlock alloc] init];
    entry.name = @"bb_entry";
    XTIRFunction* tf = [[XTIRFunction alloc] initWithName:tname
                                               returnType:(retT ?: [XTIRType voidType])
                                               paramTypes:pts
                                               entryBlock:entry];
    XTIRSymbol* tsym = [XTIRSymbol functionWithName:tname function:tf type:nil];
    tsym.attributes = [@{@"cloaked" : @NO, @"banked" : @NO, @"variadic" : @NO, @"cabi" : @NO} mutableCopy];
    [self.module addSymbol:tsym];
    [self.module addFunction:tf];

    XTIRFunction* savedFn = self.currentFunction;
    XTIRBlock* savedBlk = self.currentBlock;
    XTIRValue* savedMem = self.memToken;

    self.currentFunction = tf;
    self.currentBlock = entry;

    XTIRDefSite* pd = [XTIRDefSite parameterDef];
    NSMutableArray<XTIRValue*>* pvals = [NSMutableArray array];
    for (NSUInteger i = 0; i < pts.count; i++)
        {
        XTIRValueId vid = [tf allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                     type:pts[i]
                                                  defSite:pd];
        [tf registerValue:v];
        [pvals addObject:v];
        }
    self.memToken = pvals.lastObject;

    NSMutableArray<XTIRValue*>* fargs = [NSMutableArray array];
    for (NSUInteger i = 1; i + 1 < pvals.count; i++)
        [fargs addObject:pvals[i]];
    XTIRValue* r = [self emitCallIndirect:pvals.firstObject
                                argValues:fargs
                               resultType:retT];

    NSMutableArray<XTIROperand*>* rops = [NSMutableArray array];
    if (r)
        [rops addObject:[XTIROperand useWithValueId:r.valueId]];
    [rops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
    [self emitTerminator:XTIROpReturn operands:rops];

    self.currentFunction = savedFn;
    self.currentBlock = savedBlk;
    self.memToken = savedMem;

    self.boundTrampolines[key] = tname;
    return tname;
    }

// Build the widened `^`: { recv: fnPtr, code: tramp }.
- (nullable XTIRValue*)widenFunctionPointer:(XTIRValue*)fnPtr
                                  signature:(XTFunctionType*)sig
                                  toAggType:(XTIRType*)aggT
    {
    NSString* tname = [self boundTrampolineForSignature:sig];
    if (!tname || !aggT)
        return nil;
    XTIRSymbol* tsym = [self.module symbolForName:tname];
    if (!tsym)
        return nil;

    XTIRType* fnPtrT = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    XTIRSymbolId tid = [self.module.symbols indexOfObjectIdenticalTo:tsym];
    XTIRValue* code = [self emitInsnOpcode:XTIROpAddrOf
                                    result:fnPtrT
                                  operands:@[ [XTIROperand symWithSymbolId:tid] ]];
    if (!code)
        return nil;

    XTIRValue* agg = [self allocateValueOfType:aggT atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpAggBuild
                                                     result:agg
                                                   operands:@[ [XTIROperand useWithValueId:fnPtr.valueId],
                                                               [XTIROperand useWithValueId:code.valueId] ]
                                                     dbgLoc:nil]];
    return agg;
    }

// Is `t` a plain function pointer (so it can widen to a `^`)? Returns the
// signature, or nil.
- (nullable XTFunctionType*)fnSignatureForWidening:(XTType*)t
    {
    if (!t || t.boundMethodSignature != nil)
        return nil; // already a ^
    if (![t isKindOfClass:[XTPointerType class]])
        return nil;
    XTType* pte = ((XTPointerType*)t).pointeeType;
    return [pte isKindOfClass:[XTFunctionType class]] ? (XTFunctionType*)pte : nil;
    }

/****************************************************************************\
|* Widen args[idx] in place when the callee's parameter is a `^` (an Agg) and
|* the argument is a plain function pointer: `setAction(&freeFunc)`.
|*
|* Called from the call paths' width-adjust loops, which otherwise
|* integer-extend EVERY non-pointer param — including an Agg, emitting the
|* nonsense `ZExt %agg` from the argument's pointer width.
\****************************************************************************/
- (void)widenBoundArgAt:(NSUInteger)idx
                     in:(NSMutableArray<XTIRValue*>*)args
              ofASTType:(XTType*)srcAST
                  toAgg:(XTIRType*)dstIR
    {
    if (idx >= args.count)
        return;
    XTFunctionType* sig = [self fnSignatureForWidening:srcAST];
    if (!sig)
        return;
    XTIRValue* w = [self widenFunctionPointer:args[idx] signature:sig toAggType:dstIR];
    if (w)
        args[idx] = w;
    }

// Coerce `src` to `dstASTType`, emitting SExt / ZExt / Trunc / Bitcast
// as needed. Returns the (possibly-new) IR value. If types already
// match, returns `src` unchanged.
- (XTIRValue*)coerceValue:(XTIRValue*)src
                 fromType:(XTType*)srcASTType
                   toType:(XTType*)dstASTType
                 location:(XTSourceLocation*)loc
    {
    XTIRValue* result = [self coerceValueImpl:src
                                     fromType:srcASTType
                                       toType:dstASTType
                                     location:loc];
    // ARC ownership follows the value through coercion (#123). A +1 owned
    // temp coerced to another type (e.g. `Tracker@` → `banked:Tracker@`,
    // an upcast to `Object@`) becomes a NEW IR value; move the pending
    // registration onto it so the binding's consume / the end-of-full-
    // expression sweep act on the value that's actually live. Without this
    // the original temp stays pending and gets wrongly released.
    if (result != src && self.ownedTemps.count > 0 && [self.ownedTemps indexOfObjectIdenticalTo:src] != NSNotFound)
        {
        // Retarget the pending registration onto the coerced value IN PLACE, so
        // its recorded conditional depth (the parallel ownedTempDepths entry)
        // travels with it rather than being lost.
        NSUInteger idx = [self.ownedTemps indexOfObjectIdenticalTo:src];
        self.ownedTemps[idx] = result;
        }
    return result;
    }

- (XTIRValue*)coerceValueImpl:(XTIRValue*)src
                     fromType:(XTType*)srcASTType
                       toType:(XTType*)dstASTType
                     location:(XTSourceLocation*)loc
    {
    if (!src || !srcASTType || !dstASTType)
        return src;

    // `@`→`^` widening in a value context (`act_t^ a = &freeFunc;`). The CALL
    // paths don't come through here — they coerce against the callee's IR param
    // types — so they widen in their own width-adjust loops.
    if (dstASTType.boundMethodSignature != nil)
        {
        // Already a `^` — nothing to build.
        if (srcASTType.boundMethodSignature != nil)
            return src;

        XTFunctionType* sig = [self fnSignatureForWidening:srcASTType];
        if (sig)
            {
            XTIRType* aggT = [self irTypeForASTType:dstASTType at:loc];
            XTIRValue* w = [self widenFunctionPointer:src signature:sig toAggType:aggT];
            if (w)
                return w;
            }
        else if (srcASTType.kind == XTTypeKindPointer || (src.type && src.type.kind == XTIRTypeKindPtr))
            {
            // `(callback SIG)(p)` where p is a raw CODE address — a function
            // pointer received from C (signal()'s old handler, dlsym). Build a
            // REAL {recv=p, code=trampoline} pair so it can be called, using the
            // DESTINATION signature's trampoline (`((SIG@)recv)(args)`). Without
            // this the pointer fell into the null-pair path below and calling it
            // dispatched through a zero receiver (bug 165 / c2xc 14). recv here
            // is the code address, exactly as it is for a widened free function.
            XTIRType* aggT = [self irTypeForASTType:dstASTType at:loc];
            // boundMethodSignature is declared `XTType *` but always holds an
            // XTFunctionType (every assignment site stores the same `fn` it
            // builds the `code` field's pointee from), so cast as the sibling
            // call site at the `sig ? …` path below already does. Apple clang
            // only warns here; the cross toolchain (Homebrew clang 22) makes
            // -Wincompatible-pointer-types an error, so this broke `make
            // linux` / `make win64` while `make` stayed green.
            XTIRValue* w = [self widenFunctionPointer:src
                                            signature:(XTFunctionType*)dstASTType.boundMethodSignature
                                            toAggType:aggT];
            if (w)
                return w;
            }
        else
            {
            // A NULL bound method: `(act_t^)0`. There is no function to widen,
            // and the only sensible reading of an integer cast to a `^` is an
            // empty {recv, code} pair — which is exactly what an unimplemented
            // optional protocol method produces, and what `if (h)` tests for.
            //
            // Without this the cast fell through to the ordinary integer
            // coercion below and tried to narrow a 16-byte aggregate type out of
            // an int, producing garbage that faulted the moment it was called or
            // tested. Writing `(pred_t^)0` — the obvious way to say "no
            // callback" — crashed.
            XTIRType* aggT = [self irTypeForASTType:dstASTType at:loc];
            if (aggT)
                {
                XTIRType* vp = [XTIRType ptrToType:[XTIRType voidType]
                                            window:XTIRWindowUnbanked];
                XTIRValue* z = [self emitInsnOpcode:XTIROpConst
                                             result:vp
                                           operands:@[ [XTIROperand immIWithType:vp value:0] ]];
                if (z)
                    {
                    XTIRValue* nullBM = [self emitInsnOpcode:XTIROpAggBuild
                                                      result:aggT
                                                    operands:@[ [XTIROperand useWithValueId:z.valueId],
                                                                [XTIROperand useWithValueId:z.valueId] ]];
                    if (nullBM)
                        return nullBM;
                    }
                }
            }
        }
    // A callback VALUE coerced to a pointer/integer — `(pointer)f` on a callback
    // VARIABLE (not the designator `(pointer)&fn`, which is already correct). Its
    // code address is the recv word (field 0): for a widened free function that
    // IS the function's address, which is what a function-pointer variable must
    // become to flow to C (c2xc 13). Extract it and coerce THAT to the target;
    // without this the whole 16-byte Agg was IntToPtr'd to garbage.
    if (srcASTType.boundMethodSignature != nil && dstASTType.boundMethodSignature == nil && src.type && src.type.kind == XTIRTypeKindAgg)
        {
        XTIRType* vp = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
        XTIRValue* recv = [self emitInsnOpcode:XTIROpAggExtract
                                        result:vp
                                      operands:@[ [XTIROperand useWithValueId:src.valueId],
                                                  [XTIROperand immIWithType:[XTIRType u16Type]
                                                                      value:0] ]];
        if (recv)
            {
            src = recv;
            srcASTType = [XTType pointerType];
            }
        }
    // Same width + same signedness is NOT enough to skip the coercion: the two
    // types have to be in the same class. Once `float` is the target's native 4
    // bytes, a u32 and a float are both 4 wide and both unsigned — so this
    // early-out swallowed the int→float conversion and arm64 emitted
    // `fdiv s8, w10, s8`, a float divide reading an integer register. (A
    // pointer and a double are likewise both 8 and unsigned on arm64.)
    XTTypeKind sk = srcASTType.kind, dk = dstASTType.kind;
    BOOL srcFP = (sk == XTTypeKindFloat || sk == XTTypeKindDouble);
    BOOL dstFP = (dk == XTTypeKindFloat || dk == XTTypeKindDouble);
    BOOL srcPtr = (sk == XTTypeKindPointer);
    BOOL dstPtr = (dk == XTTypeKindPointer);
    if (srcFP == dstFP && srcPtr == dstPtr && srcASTType.byteWidth == dstASTType.byteWidth && srcASTType.isSigned == dstASTType.isSigned)
        {
        return src;
        }
    XTIRType* dstIR = [self irTypeForASTType:dstASTType at:loc];
    if (!dstIR)
        return src;
    // Detect pointer-typed source / destination — these need
    // IntToPtr / PtrToInt / Bitcast rather than the integer
    // sign-extending casts. Without this branch, an `i16 → u8@`
    // coercion would emit `ZExt %i16` with a Ptr result type,
    // which the backend then loads/stores at the wrong width.
    // A CLASS type has AST kind Class (not Pointer) but lowers to a Ptr IR type —
    // a class value IS a reference. Treat an IR-Ptr as pointer-like too, so a
    // Ptr↔Class coercion (e.g. a bare class local `C c = new C()` fed as `self`)
    // becomes a Bitcast, not a PtrToInt. On xt6502 PtrToInt NARROWS the 3-byte
    // pointer, dropping the bank byte → self reached the method bank-less and the
    // ivar write corrupted memory (bug 019); arm64's Ptr→Ptr PtrToInt was a
    // harmless no-op, which is why only xt6502 crashed.
    BOOL srcIsPtr = (srcASTType.kind == XTTypeKindPointer) || (src.type && src.type.kind == XTIRTypeKindPtr);
    BOOL dstIsPtr = (dstASTType.kind == XTTypeKindPointer) || (dstIR.kind == XTIRTypeKindPtr);
    if (srcIsPtr && dstIsPtr)
        {
        return [self emitInsnOpcode:XTIROpBitcast
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }
    if (!srcIsPtr && dstIsPtr)
        {
        return [self emitInsnOpcode:XTIROpIntToPtr
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }
    if (srcIsPtr && !dstIsPtr)
        {
        return [self emitInsnOpcode:XTIROpPtrToInt
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }
    // Float conversions — the IR names the action; backends render
    // it (arm64 native scvtf/fcvt, xt6502 iToFp/fpToI helpers). Key
    // off the ACTUAL IR types (src.type / dstIR), not the AST types:
    // a comparison node's AST resolvedType is its operand type (e.g.
    // float for `f < g`) even though the lowered value is Bool, so
    // trusting the AST type here would emit a bogus FpToUI on a Bool.
    BOOL srcIsFloat = src.type && XTIRTypeKindIsFloating(src.type.kind);
    BOOL dstIsFloat = XTIRTypeKindIsFloating(dstIR.kind);
    if (srcIsFloat || dstIsFloat)
        {
        XTIROpcode fop;
        if (srcIsFloat && dstIsFloat)
            {
            // float ↔ double: widen / narrow precision.
            fop = (dstASTType.byteWidth > srcASTType.byteWidth)
                      ? XTIROpFpExt
                      : XTIROpFpTrunc;
            }
        else if (dstIsFloat)
            {
            // int → float (signedness from the integer source).
            fop = srcASTType.isSigned ? XTIROpSIToFp : XTIROpUIToFp;
            }
        else
            {
            // float → int (signedness from the integer dest).
            fop = dstASTType.isSigned ? XTIROpFpToSI : XTIROpFpToUI;
            }
        return [self emitInsnOpcode:fop
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }
    // Width/signedness for the widen/trunc decision must come from the ACTUAL
    // IR value, not the AST type — a comparison's AST resolvedType is its
    // OPERAND type (e.g. u32 for `e > f`, or float for `f < g`) while the value
    // is a 1-byte unsigned Bool. Trusting the AST width picked Bitcast (4==4)
    // for `(i32)(u32 > u32)`, splicing 3 garbage high bytes on a byte-addressed
    // backend (and Trunc for a double comparison). Treat a Bool source as the
    // 1-byte unsigned value it is.
    BOOL srcIsBool = src.type && src.type.kind == XTIRTypeKindBool;
    NSUInteger srcW = srcIsBool ? 1 : srcASTType.byteWidth;
    BOOL srcSigned = srcIsBool ? NO : srcASTType.isSigned;
    XTIROpcode op;
    if (dstASTType.byteWidth > srcW)
        {
        op = srcSigned ? XTIROpSExt : XTIROpZExt;
        }
    else if (dstASTType.byteWidth < srcW)
        {
        op = XTIROpTrunc;
        }
    else
        {
        op = XTIROpBitcast;
        }
    return [self emitInsnOpcode:op
                         result:dstIR
                       operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
    }

- (XTIRValue*)emitCall:(XTIRSymbolId)calleeSymbolId
              callConv:(XTIRCallConv*)cc
             argValues:(NSArray<XTIRValue*>*)args
            resultType:(nullable XTIRType*)resultType
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
    [ops addObject:[XTIROperand symWithSymbolId:calleeSymbolId]];
    for (XTIRValue* a in args)
        {
        [ops addObject:[XTIROperand useWithValueId:a.valueId]];
        }
    [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

    XTIRValue* r = nil;
    if (resultType && resultType.kind != XTIRTypeKindVoid)
        {
        r = [self allocateValueOfType:resultType atSite:self.currentBlock];
        }
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    // Pick the call opcode from the callee's placement attributes so it
    // matches IR-SPEC §12.9 (a plain Call may not target a banked or
    // cloaked symbol — the verifier compares the OPCODE, not just the
    // callConv). The call paths already select a matching callConv; this
    // keeps the opcode in lockstep, and since emitCall always has a Sym
    // callee, deriving from the symbol makes every caller correct.
    XTIROpcode callOp = XTIROpCall;
    XTIRCallConv* conv = cc;
    XTIRSymbol* callee = [self.module symbolForId:calleeSymbolId];
    if (callee.attributes[@"cloaked"].boolValue)
        {
        callOp = XTIROpCallCloaked;
        conv = [XTIRCallConv cloaked];
        }
    else if (callee.attributes[@"banked"].boolValue)
        {
        callOp = XTIROpCallBanked;
        conv = [XTIRCallConv banked];
        }
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:callOp
                                               result:r
                                             operands:ops
                                             callConv:conv
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    // A call to a `throws` function may have raised. Emitted here, at the single
    // choke point every direct call goes through, rather than at each of the
    // several call-lowering return sites — one of which would eventually be
    // missed. Costs a load and a not-taken branch on the success path.
    if (callee.attributes[@"throws"].boolValue)
        {
        [self emitErrorCheckAfterCallAt:nil];
        }
    return r;
    }

/****************************************************************************\
|* `&obj.method` — build the {recv, code} bound-method fat pointer.
|*
|* The code word is:
|*   slot stamped → VTblLoad(recv, slot). The `^` then picks up the
|*                  receiver's RUNTIME override, and comes back NULL when the
|*                  class left that slot empty (an unimplemented `optional`
|*                  protocol method) or when recv is null. That null IS the
|*                  respondsTo test at the call site.
|*   no slot      → AddrOf(Class$method), a direct symbol — the same path
|*                  `&freeFunction` already takes.
|*
|* Result is an AggBuild of the 2-field struct sema resolved the expression
|* to, so all the existing struct-by-value machinery (pass, return, store)
|* carries it from here — no new ABI.
\****************************************************************************/
- (XTIRValue*)lowerBoundMethodRef:(XTMemberAccessNode*)ma
                           ofExpr:(XTUnaryExprNode*)node
    {
    XTIRType* aggT = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!aggT)
        return nil;

    XTIRType* fnPtrT = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];

    // `&Class.staticMethod` — no receiver, so this is a plain FUNCTION POINTER,
    // not a fat pointer. Sema resolved it to Ptr(FuncType) rather than the
    // 2-field `^` struct; emit the bare symbol address, the same shape
    // `&freeFunction` produces. It then reaches a `^` parameter through the
    // ordinary `@`→`^` widening, with no special case.
    XTMethodDeclNode* bmd = (XTMethodDeclNode*)ma.resolvedBoundMethod;
    if (bmd.isStatic)
        {
        NSString* sname = [NSString stringWithFormat:@"%@$%@",
                                                     ma.resolvedBoundClass, (bmd.mangledName ?: bmd.methodName)];
        XTIRSymbol* ssym = [self.module symbolForName:sname];
        if (!ssym)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString
                                         stringWithFormat:@"lowering: static method '%@' has no symbol", sname]];
            return nil;
            }
        XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:ssym];
        return [self emitInsnOpcode:XTIROpAddrOf
                             result:fnPtrT
                           operands:@[ [XTIROperand symWithSymbolId:sid] ]];
        }

    XTIRValue* recv = [self lowerExpression:ma.base];
    if (!recv)
        return nil;

    XTIRValue* code = nil;

    if (sItableProtocols && ma.resolvedBoundProtocol.length && ma.resolvedBoundProtoIndex != nil)
        {
        // `&delegate.method` through a PROTOCOL receiver: the same itable lookup,
        // without the call. A null result means the class did not implement an
        // `optional` — which is exactly what makes respondsTo a null test on the `^`.
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        [ops addObject:[XTIROperand useWithValueId:recv.valueId]];
        [ops addObject:[XTIROperand immIWithType:[XTIRType u32Type]
                                           value:(int64_t)xtProtocolId(ma.resolvedBoundProtocol)]];
        [ops addObject:[XTIROperand immIWithType:[XTIRType u16Type]
                                           value:ma.resolvedBoundProtoIndex.longLongValue]];
        [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

        code = [self allocateValueOfType:fnPtrT atSite:self.currentBlock];
        XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                               atSite:self.currentBlock];
        XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpProtoLoad
                                                   result:code
                                                 operands:ops
                                                   dbgLoc:nil];
        insn.memoryResult = newMem;
        [self.currentBlock appendInstruction:insn];
        self.memToken = newMem;
        }
    else if (ma.resolvedBoundChainSlot != nil && ma.resolvedBoundChainAnchor.length)
        {
        // §4.2: read the code word out of the receiver's CATEGORY CHAIN — same
        // load sequence the call site uses, minus the call.
        code = [self emitCatMethodLoad:recv
                                anchor:ma.resolvedBoundChainAnchor
                                  slot:ma.resolvedBoundChainSlot.unsignedIntegerValue];
        }
    else if (ma.resolvedBoundSlot != nil)
        {
        // Virtual: read the impl out of recv's vtable. Carries a memory token
        // (see XTIROpcodeTouchesMemory) so it can't be hoisted above the
        // `new` that installs the vtable pointer.
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        [ops addObject:[XTIROperand useWithValueId:recv.valueId]];
        [ops addObject:[XTIROperand immIWithType:[XTIRType u16Type]
                                           value:ma.resolvedBoundSlot.longLongValue + (int64_t)XTVtblHeaderWords()]];
        [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

        code = [self allocateValueOfType:fnPtrT atSite:self.currentBlock];
        XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                               atSite:self.currentBlock];
        XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpVTblLoad
                                                   result:code
                                                 operands:ops
                                                   dbgLoc:nil];
        insn.memoryResult = newMem;
        [self.currentBlock appendInstruction:insn];
        self.memToken = newMem;
        }
    else
        {
        // Non-virtual: bind the concrete symbol directly.
        XTMethodDeclNode* m = (XTMethodDeclNode*)ma.resolvedBoundMethod;
        NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                       ma.resolvedBoundClass,
                                                       (m.mangledName ?: m.methodName)];
        XTIRSymbol* msym = [self.module symbolForName:symName];
        if (!msym)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString
                                         stringWithFormat:@"lowering: bound method '%@' has no symbol",
                                                          symName]];
            return nil;
            }
        XTIRSymbolId mid = [self.module.symbols indexOfObjectIdenticalTo:msym];
        code = [self emitInsnOpcode:XTIROpAddrOf
                             result:fnPtrT
                           operands:@[ [XTIROperand symWithSymbolId:mid] ]];
        }
    if (!code)
        return nil;

    // Truthiness now tests RECV, so an UNIMPLEMENTED optional method — which has
    // code == 0 but a perfectly good receiver — must force recv to 0 as well, or
    // `if (h)` would report it as present. This is the mirror of the null-receiver
    // rule above (which forces code = 0), and it is what lets the weak runtime
    // treat every node uniformly: zero word 0.
    //
    // A slot LOAD is what VTblLoad returns, so this only bites the virtual path;
    // for a direct symbol `code` is never 0 and the Select folds away.
    if (ma.resolvedBoundSlot != nil)
        {
        XTIRValue* zeroP = [self allocateValueOfType:fnPtrT atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zeroP
                                                       operands:@[ [XTIROperand immIWithType:fnPtrT value:0] ]
                                                         dbgLoc:nil]];
        XTIRValue* codeNull = [self allocateValueOfType:[XTIRType boolType]
                                                 atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                         result:codeNull
                                                       operands:@[ [XTIROperand useWithValueId:code.valueId],
                                                                   [XTIROperand useWithValueId:zeroP.valueId] ]
                                                      predicate:XTIRICmpEQ
                                                         dbgLoc:nil]];
        XTIRValue* recvSel = [self allocateValueOfType:recv.type
                                                atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                         result:recvSel
                                                       operands:@[ [XTIROperand useWithValueId:codeNull.valueId],
                                                                   [XTIROperand useWithValueId:zeroP.valueId],
                                                                   [XTIROperand useWithValueId:recv.valueId] ]
                                                         dbgLoc:nil]];
        recv = recvSel;
        }

    XTIRValue* agg = [self allocateValueOfType:aggT atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpAggBuild
                                                     result:agg
                                                   operands:@[ [XTIROperand useWithValueId:recv.valueId],
                                                               [XTIROperand useWithValueId:code.valueId] ]
                                                     dbgLoc:nil]];
    return agg;
    }

// Virtual dispatch through the receiver's vtable (protocol / interface
// calls). Operand shape matches both backends' VTblDispatch handlers:
// [recv, slot:ImmI, args…, mem]. The backend follows recv → vtable ptr
// (obj[0..1]) → method ptr (vtbl[slot*2]) and calls it. `slot` is the
// sema-resolved virtual slot, which must equal the slot each conforming
// class placed the method at in its own vtable.
/****************************************************************************\
|* Dispatch through a protocol, identified by a VALUE (its id) and a
|* protocol-relative index — neither of which any two modules need to agree on in
|* advance. See private:docs/Design/protocol-slot-collisions.md.
\****************************************************************************/
- (XTIRValue*)emitProtoDispatch:(XTIRValue*)recv
                       protocol:(NSString*)protoName
                          index:(NSUInteger)idx
                      argValues:(NSArray<XTIRValue*>*)args
                     resultType:(nullable XTIRType*)resultType
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
    [ops addObject:[XTIROperand useWithValueId:recv.valueId]];
    [ops addObject:[XTIROperand immIWithType:[XTIRType u32Type]
                                       value:(int64_t)xtProtocolId(protoName)]];
    [ops addObject:[XTIROperand immIWithType:[XTIRType u16Type] value:(int64_t)idx]];
    for (XTIRValue* a in args)
        [ops addObject:[XTIROperand useWithValueId:a.valueId]];
    [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

    XTIRValue* r = nil;
    if (resultType && resultType.kind != XTIRTypeKindVoid)
        r = [self allocateValueOfType:resultType atSite:self.currentBlock];
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpProtoDispatch
                                               result:r
                                             operands:ops
                                             callConv:[XTIRCallConv standard]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    return r;
    }

- (XTIRValue*)emitVTblDispatch:(XTIRValue*)recv
                          slot:(NSUInteger)slot
                     argValues:(NSArray<XTIRValue*>*)args
                    resultType:(nullable XTIRType*)resultType
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
    [ops addObject:[XTIROperand useWithValueId:recv.valueId]];
    // The vtable's header words (parent link / itable / category chain) sit in
    // front of the method slots — see XTVtblHeaderWords. Done HERE and in
    // emitVTblLoad only, so methodSlot / resolvedVirtualSlot stay 0-based
    // everywhere else.
    [ops addObject:[XTIROperand immIWithType:[XTIRType u16Type]
                                       value:(int64_t)(slot + XTVtblHeaderWords())]];
    for (XTIRValue* a in args)
        {
        [ops addObject:[XTIROperand useWithValueId:a.valueId]];
        }
    [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

    XTIRValue* r = nil;
    if (resultType && resultType.kind != XTIRTypeKindVoid)
        {
        r = [self allocateValueOfType:resultType atSite:self.currentBlock];
        }
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpVTblDispatch
                                               result:r
                                             operands:ops
                                             callConv:[XTIRCallConv standard]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    return r;
    }

/****************************************************************************\
|* Dispatch a method a category added to a class from ANOTHER module
|* (separate-compilation §4.2) — through the category chain rather than a
|* vtable slot, because that class's vtable is already emitted inside a
|* library we cannot relink.
|*
|*    vt    = obj[0]                     the receiver's vtable
|*    chain = vt[2]                      the chain word (see XTVtblHeaderWords)
|*    t     = chain ? chain : &anchor    null ⇒ a class this module never saw
|*    own   = t[0]                       the table's OWNER ANCHOR (§4.3b)
|*    tbl   = own == &anchor ? t : &anchor
|*    fn    = tbl[1 + k]                 entry 0 is the owner anchor
|*    fn(obj, args…)
|*
|* Three loads, a compare and two selects — O(1), no selectors, no method
|* cache, and no search: the chain slot `k` and the anchor are compile-time
|* constants. The anchor is this compilation's own fallback table
|* (`<Host>$cat$<names>`), whose entry [0] points at ITSELF, so the null case
|* lands in the same compare.
|*
|* The ownership test is what makes MULTIPLE extenders sound (§4.3b): a class
|* compiled by another module carries THAT module's chain table, whose [0] is
|* a different anchor — and since a class that never compiled against this
|* category cannot override it, "not mine" has the same right answer null
|* always had: this compilation's fallback.
\****************************************************************************/
- (XTIRValue*)emitCatDispatch:(XTIRValue*)recv
                       anchor:(NSString*)anchor
                         slot:(NSUInteger)slot
                    argValues:(NSArray<XTIRValue*>*)args
                   resultType:(nullable XTIRType*)resultType
    {
    XTIRValue* fn = [self emitCatMethodLoad:recv anchor:anchor slot:slot];
    if (!fn)
        return nil;
    NSMutableArray<XTIRValue*>* callArgs = [NSMutableArray arrayWithObject:recv];
    [callArgs addObjectsFromArray:args];
    return [self emitCallIndirect:fn argValues:callArgs resultType:resultType];
    }

// The address half of emitCatDispatch — also what `&obj.categoryMethod` takes.
- (nullable XTIRValue*)emitCatMethodLoad:(XTIRValue*)recv
                                  anchor:(NSString*)anchor
                                    slot:(NSUInteger)slot
    {
    XTIRType* voidPtr = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    XTIRType* ppVoid = [XTIRType ptrToType:voidPtr window:XTIRWindowUnbanked];

    XTIRSymbol* tblSym = [self.module symbolForName:anchor];
    if (!tblSym)
        {
        [self softFailLoweringAt:nil
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: no category table '%@' for a chain dispatch", anchor]];
        return nil;
        }
    XTIRSymbolId tid = [self.module.symbols indexOfObjectIdenticalTo:tblSym];

    XTIRValue* objPP = [self emitInsnOpcode:XTIROpBitcast
                                     result:ppVoid
                                   operands:@[ [XTIROperand useWithValueId:recv.valueId] ]];
    XTIRValue* vtbl = [self emitLoad:objPP pointeeType:voidPtr];
    XTIRValue* vtPP = [self emitInsnOpcode:XTIROpBitcast
                                    result:ppVoid
                                  operands:@[ [XTIROperand useWithValueId:vtbl.valueId] ]];
    XTIRValue* chIdx = [self emitU16Const:(uint32_t)XTVtblCatChainIndex()];
    XTIRValue* chAddr = [self emitInsnOpcode:XTIROpElementAddr
                                      result:ppVoid
                                    operands:@[ [XTIROperand useWithValueId:vtPP.valueId],
                                                [XTIROperand useWithValueId:chIdx.valueId] ]];
    XTIRValue* chain = [self emitLoad:chAddr pointeeType:voidPtr];

    XTIRValue* fallback = [self emitInsnOpcode:XTIROpAddrOf
                                        result:voidPtr
                                      operands:@[ [XTIROperand symWithSymbolId:tid] ]];
    XTIRValue* nullP = [self emitInsnOpcode:XTIROpIntToPtr
                                     result:voidPtr
                                   operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];
    XTIRValue* isNull = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                   result:isNull
                                                                 operands:@[ [XTIROperand useWithValueId:chain.valueId],
                                                                             [XTIROperand useWithValueId:nullP.valueId] ]
                                                                predicate:XTIRICmpEQ
                                                                   dbgLoc:nil]];
    XTIRValue* t = [self allocateValueOfType:voidPtr atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                                   result:t
                                                                 operands:@[ [XTIROperand useWithValueId:isNull.valueId],
                                                                             [XTIROperand useWithValueId:fallback.valueId],
                                                                             [XTIROperand useWithValueId:chain.valueId] ]
                                                                   dbgLoc:nil]];

    // §4.3b ownership: t[0] is the table's owner anchor. Mine ⇒ use it (a
    // class of this compilation, possibly overriding); anyone else's ⇒ my
    // fallback, which is the null case's answer generalised — a class that
    // never compiled against this category cannot override it. The fallback's
    // own [0] points at itself, so the null-select above lands here equal.
    XTIRType* pp = ppVoid;
    XTIRValue* tPP = [self emitInsnOpcode:XTIROpBitcast
                                   result:pp
                                 operands:@[ [XTIROperand useWithValueId:t.valueId] ]];
    XTIRValue* ownIdx = [self emitU16Const:0];
    XTIRValue* ownAddr = [self emitInsnOpcode:XTIROpElementAddr
                                       result:pp
                                     operands:@[ [XTIROperand useWithValueId:tPP.valueId],
                                                 [XTIROperand useWithValueId:ownIdx.valueId] ]];
    XTIRValue* own = [self emitLoad:ownAddr pointeeType:voidPtr];
    XTIRValue* isMine = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                   result:isMine
                                                                 operands:@[ [XTIROperand useWithValueId:own.valueId],
                                                                             [XTIROperand useWithValueId:fallback.valueId] ]
                                                                predicate:XTIRICmpEQ
                                                                   dbgLoc:nil]];
    XTIRValue* tbl = [self allocateValueOfType:voidPtr atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                                   result:tbl
                                                                 operands:@[ [XTIROperand useWithValueId:isMine.valueId],
                                                                             [XTIROperand useWithValueId:t.valueId],
                                                                             [XTIROperand useWithValueId:fallback.valueId] ]
                                                                   dbgLoc:nil]];

    XTIRValue* tblPP = [self emitInsnOpcode:XTIROpBitcast
                                     result:ppVoid
                                   operands:@[ [XTIROperand useWithValueId:tbl.valueId] ]];
    XTIRValue* fnIdx = [self emitU16Const:(uint32_t)(slot + 1)]; // entry 0 = owner anchor
    XTIRValue* fnAddr = [self emitInsnOpcode:XTIROpElementAddr
                                      result:ppVoid
                                    operands:@[ [XTIROperand useWithValueId:tblPP.valueId],
                                                [XTIROperand useWithValueId:fnIdx.valueId] ]];
    return [self emitLoad:fnAddr pointeeType:voidPtr];
    }

// Indirect call through a function pointer (`fp(args)`). Operand shape
// matches both backends' CallIndirect handlers: [fnPtr, args…, mem].
// The backend stages the pointer value and jumps through it (xt6502:
// `__xt_indjmp`; arm64: `blr`). The pointer comes from `&function`
// (AddrOf of the function symbol) or any FuncType@ value.
- (XTIRValue*)emitCallIndirect:(XTIRValue*)fnPtr
                     argValues:(NSArray<XTIRValue*>*)args
                    resultType:(nullable XTIRType*)resultType
    {
    NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
    [ops addObject:[XTIROperand useWithValueId:fnPtr.valueId]];
    for (XTIRValue* a in args)
        {
        [ops addObject:[XTIROperand useWithValueId:a.valueId]];
        }
    [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];

    XTIRValue* r = nil;
    if (resultType && resultType.kind != XTIRTypeKindVoid)
        {
        r = [self allocateValueOfType:resultType atSite:self.currentBlock];
        }
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpCallIndirect
                                               result:r
                                             operands:ops
                                             callConv:[XTIRCallConv standard]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    return r;
    }

// Store the class's vtable address into the freshly-allocated instance's
// field 0 (the vtable pointer), so a later VTblDispatch through the
// object reaches the right method body. Done here in the lowering — not
// in the `_xtc_new_<T>` allocator helper — so it's backend- and
// helper-agnostic (the corpus's generic allocator stub only allocates).
- (void)emitVtableInitFor:(XTIRValue*)instance class:(nullable XTIRClassInfo*)ci
    {
    if (!ci || !instance || !ci.needsVtable)
        return;
    // Store the vtable's address into slot 0 as a POINTER (task #67), so
    // each backend writes its native pointer width into the pointer-typed
    // slot: xt6502 writes 2 bytes (the same value it always did — the
    // dropped PtrToInt was a no-op there), arm64 writes 8. VTblDispatch
    // reads it back at the same width (xt6502 `obj[0..1]`; arm64
    // `ldr x16,[x0]`). The previous PtrToInt→U16 truncated to 2 bytes,
    // which left arm64 reading a 2-good/6-garbage 8-byte pointer and
    // mis-dispatching. Slot 0 is already a Ptr field in the instance
    // layout, so the ivars after it stay correctly offset on both
    // backends (arm64FieldOffset sizes the slot at 8).
    XTIRType* fnPtrT = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    // The field-address pointer is tagged XtData so the xt6502 backend
    // banks-selects ($83 ← byte 2) before the store. A `new`-allocated
    // instance is typed Ptr(Agg, Unbanked) but physically lives in a heap
    // data bank, with its bank carried in byte 2 (FieldAddr propagates it
    // from the instance). VTblDispatch already reads obj[0..1] after
    // selecting the receiver's byte-2 bank, so without this the vtable
    // pointer was stored to bank 0 while the dispatch read it from the
    // object's real bank → null vtable ptr → jump to $0000. Tagging only
    // this field-address (not the instance's selfPtrType) keeps ordinary
    // ivar load/store untouched — they stay in the bank the allocator
    // leaves live, which is where the dealloc header / ARC machinery
    // expects them. On arm64 windowId is ignored, so this is a no-op there.
    XTIRType* slotPtrT = [XTIRType ptrToType:fnPtrT window:XTIRWindowXtData];
    XTIRValue* fa = [self emitFieldAddr:instance fieldIndex:0 resultType:slotPtrT];
    XTIRValue* vtblPtr = [self emitInsnOpcode:XTIROpAddrOf
                                       result:fnPtrT
                                     operands:@[ [XTIROperand symWithSymbolId:ci.vtableSymbolId] ]];
    [self emitStore:fa value:vtblPtr];
    }

// Zero-initialise the ivar slots of a stack-allocated (value) class
// instance. The `new` (heap) path gets zeroed storage from the
// allocator; a stack instance owns its frame slot, which starts as
// garbage. Zeroing matters for strong class-pointer ivars: the first
// `inst.field = expr` store runs an ARC release-old on the field's
// current value, which must read as null (a no-op) rather than a stale
// pointer. Walks the instance layout's ivars (field 0 is the vtable
// pointer, seeded separately by emitVtableInitFor:); inherited ivars
// are already merged into ci.ivarFieldIndex by the class pre-scan.
- (void)emitZeroInitIvarsFor:(XTIRValue*)instance class:(nullable XTIRClassInfo*)ci
    {
    if (!ci || !instance)
        return;

    // A WEAK ivar's two hidden LINK words must be zeroed too. They are not in
    // ivarFieldIndex (which maps a name to its PAYLOAD field), so the loop below
    // never sees them — and the payload loop also skips Agg fields, which is what
    // a weak `^` is.
    //
    // Missing this was invisible on macOS and fatal on Linux: a `new` in a loop
    // frees and REUSES blocks, so on Linux the object came back dirty and the
    // links held garbage — the first unregister then followed a garbage `pprev`
    // and wrote through it. macOS happened to hand back fresh zero pages.
    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    XTIRType* linkPtr = [XTIRType ptrToType:linkTy window:XTIRWindowUnbanked];
    // FIELD order, not the dictionary's. `ivarFieldIndex` is a hash table, so
    // iterating it directly put the zero-init stores in an order that is a
    // property of the hash and not of the program — the emitted IR differed
    // between an object with the same ivars under a different insertion
    // history. `make determinism` never saw it because it compiles the same
    // input twice; the self-hosted port disagreed on the first library class
    // with more than a couple of ivars.
    NSArray<NSString*>* zeroOrder =
        [ci.ivarFieldIndex.allKeys sortedArrayUsingComparator:
                                       ^NSComparisonResult(NSString* a, NSString* b) {
                                         return [ci.ivarFieldIndex[a] compare:ci.ivarFieldIndex[b]];
                                       }];
    for (NSString* ivarName in zeroOrder)
        {
        if (![self astTypeIsWeakSlot:ci.ivarASTType[ivarName]])
            continue;
        NSUInteger pidx = ci.ivarFieldIndex[ivarName].unsignedIntegerValue;
        if (pidx < 2)
            continue; // links precede the payload
        for (NSUInteger k = pidx - 2; k < pidx; k++)
            {
            XTIRValue* fa = [self emitFieldAddr:instance
                                     fieldIndex:k
                                     resultType:linkPtr];
            if (!fa)
                continue;
            // A Const PER STORE, not one cached across all of them. A single
            // def feeding several stores stays live across them, so the back
            // end materialises it (`mov x10, #0`) and THEN folds every store
            // to `str xzr` anyway — leaving one dead instruction in every
            // class with an auto-zeroing ivar. One def per use folds away
            // completely, and it is what the shipped compiler emits.
            XTIRValue* z = [self allocateValueOfType:linkTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                             result:z
                                                           operands:@[ [XTIROperand immIWithType:linkTy
                                                                                           value:0] ]
                                                             dbgLoc:nil]];
            [self emitStore:fa value:z];
            }
        }

    for (NSString* ivarName in zeroOrder)
        {
        NSNumber* idx = ci.ivarFieldIndex[ivarName];
        XTType* ivarAST = ci.ivarASTType[ivarName];
        if (!idx || !ivarAST)
            continue;
        XTIRType* fieldIRType = [self irTypeForASTTypeQuiet:ivarAST];
        // Only scalar / pointer ivars get a single-Store zero. Aggregate
        // ivars (nested struct/array) are left untouched — none of the
        // current stack-class fixtures use them, and a partial zero would
        // be worse than none. (A future task can recurse if needed.)
        if (!fieldIRType || fieldIRType.kind == XTIRTypeKindAgg || fieldIRType.kind == XTIRTypeKindVoid)
            continue;
        XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
        XTIRValue* fa = [self emitFieldAddr:instance
                                 fieldIndex:idx.unsignedIntegerValue
                                 resultType:fieldPtrType];
        if (!fa)
            continue;
        XTIRValue* zero = nil;
        if (fieldIRType.kind == XTIRTypeKindPtr)
            {
            // Null pointer: Const #0:U16 → IntToPtr (matches the
            // uninitialised-class-pointer path in lowerVarDecl).
            XTIRValue* z = [self allocateValueOfType:[XTIRType u16Type]
                                              atSite:self.currentBlock];
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:z
                                                   operands:@[ [XTIROperand immIWithType:[XTIRType u16Type] value:0] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:cz];
            zero = [self emitInsnOpcode:XTIROpIntToPtr
                                 result:fieldIRType
                               operands:@[ [XTIROperand useWithValueId:z.valueId] ]];
            }
        else
            {
            zero = [self allocateValueOfType:fieldIRType atSite:self.currentBlock];
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:fieldIRType value:0] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:cz];
            }
        if (zero)
            [self emitStore:fa value:zero];
        }
    }

#pragma mark - Memory-threaded op helpers (Load / Store / Retain / Release)

- (XTIRValue*)emitLoad:(XTIRValue*)pointer pointeeType:(XTIRType*)pointeeType
    {
    XTIRValue* r = [self allocateValueOfType:pointeeType atSite:self.currentBlock];
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpLoad
                                               result:r
                                             operands:@[ [XTIROperand useWithValueId:pointer.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    return r;
    }

// Emit an abstract memory-effecting varargs op (VaStart / VaArg) on the cursor
// slot. The op stays unexpanded in the front-end IR; a per-target lowering (the
// default pack-buffer pass for 6502/m68k, or the native AAPCS path in the
// arm9/arm64 backend) expands it. Threads the memory token exactly like a
// load/store so ordering is preserved. `resultType` nil ⇒ no result (VaStart).
- (nullable XTIRValue*)emitVaMemOp:(XTIROpcode)op
                        cursorAddr:(XTIRValue*)cursorAddr
                        resultType:(nullable XTIRType*)resultType
    {
    XTIRValue* r = (resultType && resultType.kind != XTIRTypeKindVoid)
                       ? [self allocateValueOfType:resultType atSite:self.currentBlock]
                       : nil;
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:op
                                               result:r
                                             operands:@[ [XTIROperand useWithValueId:cursorAddr.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    return r;
    }

- (void)emitStore:(XTIRValue*)pointer value:(XTIRValue*)value
    {
    [self emitStore:pointer value:value consumesOwnership:YES];
    }

// `consumesOwnership:NO` is for a store into a slot that does NOT own what it
// holds — today, the `__xtc_va_buf` marshalling area.
//
// Storing a +1 owned temp into memory that DOES own it (a strong slot, an
// array cell, a struct field, a pinned local) transfers ownership, and the
// end-of-full-expression sweep must not release it as well (#123). That was a
// catch-all here, on the reasoning that consuming a temp stored into a
// non-owning slot "only leaks, which is the safe side". It is the safe side,
// and it did leak: `printf("%@", obj.child())` dropped the child's release on
// every call, because a variadic argument goes through the buffer (bug 037).
// A non-owning store now says so instead.
- (void)emitStore:(XTIRValue*)pointer value:(XTIRValue*)value
    consumesOwnership:(BOOL)consumes
    {
    if (consumes)
        [self consumeOwnedTemp:value];
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpStore
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:pointer.valueId],
                                                         [XTIROperand useWithValueId:value.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }

// Weak side-table ops (private:docs/bugs/011 #6). WeakRegister records
// (obj → slot-address) so the runtime zeroes `slot` the instant `obj`'s
// refcount reaches 0; WeakUnregister drops the entry for `slot` (on
// re-point and when the holder is itself torn down). Both thread the
// memory token like Store. A weak READ is a plain Load — the slot holds
// the pointer while the pointee is alive and 0 once it has been zeroed.
- (void)emitWeakRegisterSlot:(XTIRValue*)slot obj:(XTIRValue*)obj
    {
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpWeakRegister
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:slot.valueId],
                                                         [XTIROperand useWithValueId:obj.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }
- (void)emitWeakUnregisterSlot:(XTIRValue*)slot
    {
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpWeakUnregister
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:slot.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }

/****************************************************************************\
|* Re-link every auto-zeroing slot inside a struct that has just been COPIED
|* wholesale into `dstAddr`.
|*
|* An aggregate copy is a Load+Store of the whole struct, so it duplicates the
|* payload AND the two hidden link words — but linking is a side effect the copy
|* never performs. The destination therefore looks registered and is not: when
|* the referent dies, the runtime walks its chain, finds only the SOURCE slot,
|* and zeroes that one. The copy keeps its stale pointer, `if (h.a)` still tests
|* true, and the call goes through freed memory. Both slot kinds were affected —
|* `weak:T@` and `^` alike, since both ride the same links.
|*
|* Zeroing the copied links FIRST is not optional. `_xtc_weak_register` opens
|* with `xt_weak_unreg(slot)`, which unlinks using the slot's CURRENT links — so
|* registering a fresh copy while it still holds the source's pprev/next would
|* splice the destination into the source's neighbours and write through them.
|*
|* Registering unconditionally afterwards is safe: the runtime ignores a null
|* obj, and it checks the object header's magic before touching anything, so a
|* `^` carrying a widened function (recv = a code address, not a heap block) is
|* rejected there rather than corrupting `.text`.
\****************************************************************************/
- (void)relinkWeakSlotsAfterCopyAt:(XTIRValue*)dstAddr
                           astType:(nullable XTType*)ty
    {
    if (!dstAddr || ![ty isKindOfClass:[XTStructType class]])
        return;
    XTStructType* st = (XTStructType*)ty;

    XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                  window:XTIRWindowUnbanked];
    XTIRType* ptrPtr = [XTIRType ptrToType:ptrT window:XTIRWindowUnbanked];

    NSUInteger idx = 0;
    for (XTStructField* f in st.fields)
        {
        if (![self astTypeIsWeakSlot:f.fieldType])
            {
            idx++;
            continue;
            }
        // The link words are real IR fields immediately before the payload, so
        // they address like any other field — idx and idx+1, with the payload
        // landing at idx+2 (see the layout builder above).
        NSUInteger linkIdx = idx, payloadIdx = idx + 2;
        XTIRValue* zero = [self allocateValueOfType:ptrT atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:zero
                                                       operands:@[ [XTIROperand immIWithType:ptrT value:0] ]
                                                         dbgLoc:nil]];
        for (NSUInteger k = 0; k < 2; k++)
            {
            XTIRValue* la = [self emitFieldAddr:dstAddr
                                     fieldIndex:(uint32_t)(linkIdx + k)
                                     resultType:ptrPtr];
            if (la && zero)
                [self emitStore:la value:zero consumesOwnership:NO];
            }

        XTIRType* payloadIR = [self irTypeForASTTypeQuiet:f.fieldType];
        XTIRValue* slotAddr = payloadIR
                                  ? [self emitFieldAddr:dstAddr
                                             fieldIndex:(uint32_t)payloadIdx
                                             resultType:[XTIRType ptrToType:payloadIR
                                                                     window:XTIRWindowUnbanked]]
                                  : nil;
        if (slotAddr && payloadIR)
            {
            XTIRValue* payload = [self emitLoad:slotAddr pointeeType:payloadIR];
            if (payload)
                {
                if ([self astTypeIsWeakBound:f.fieldType])
                    {
                    // rhsNode:nil — there is no syntactic RHS to inspect for a
                    // literal widening, and none is needed: the runtime's header
                    // check rejects a code address anyway.
                    [self emitWeakBoundRegisterAt:slotAddr
                                            value:payload
                                        boundType:f.fieldType
                                          rhsNode:nil];
                    }
                else
                    {
                    [self emitWeakRegisterSlot:slotAddr obj:payload];
                    }
                }
            }
        idx += 3; // two links + the payload
        }
    }

// YES if `ty` is a `weak:` qualified pointer to a class.
- (BOOL)astTypeIsWeakClassPointer:(nullable XTType*)ty
    {
    if (![ty isKindOfClass:[XTPointerType class]])
        return NO;
    XTPointerType* pt = (XTPointerType*)ty;
    return pt.isWeak && pt.pointeeType && pt.pointeeType.kind == XTTypeKindClass;
    }

/****************************************************************************\
|* YES if `ty` is a bound method held in a slot that must AUTO-ZERO.
|*
|* Every STORED `^` qualifies — the `weak:` spelling is accepted but redundant.
|* There is no unowned form, and deliberately so:
|*
|* A `^` cannot self-check. `if (h)` tests the CODE word, and the code stays
|* valid forever — only recv dies. So an unowned `^` whose receiver is freed
|* passes the one guard a careful programmer writes, and calls straight through
|* the dead object. Nothing can detect it. The only argument for allowing it was
|* the cost of a side-table slot, and that is an argument for a better table,
|* not for handing the user a hazard they cannot guard against.
|*
|* Costs nothing where it buys nothing: a `^` holding a WIDENED function has a
|* code address in recv, and emitWeakBoundRegisterAt: skips registering those.
\****************************************************************************/
- (BOOL)astTypeIsWeakBound:(nullable XTType*)ty
    {
    return ty != nil && ty.boundMethodSignature != nil;
    }

/****************************************************************************\
|* Register a `weak:` bound method in the weak side table.
|*
|* A `^` never OWNS its recv, so `weak:` here doesn't mean "don't retain"
|* (nothing retains it anyway) — it means AUTO-ZERO: the `^` must go falsy the
|* instant the receiver dies. AppKit's target semantics.
|*
|* The slot registered is the `^`'s CODE word, not its recv. Zeroing recv would
|* leave code non-null, so `if (h)` — which tests CODE — would stay TRUE and the
|* call would pass `self = 0`: worse than a dangling pointer. Zeroing code makes
|* the `^` correctly falsy, and recv is then never read.
|*
|* SKIPS a widened function pointer. Its recv is a CODE address: it is not a
|* heap block, nothing ever frees it, so the entry could never fire — it would
|* just permanently consume one of the weak table's bounded slots (64 by
|* default). A UI with a few dozen free-function actions could exhaust the table
|* with entries that are pure waste.
\****************************************************************************/
- (void)emitWeakBoundRegisterAt:(XTIRValue*)fatAddr
                          value:(XTIRValue*)fatVal
                      boundType:(XTType*)boundType
                        rhsNode:(nullable XTASTNode*)rhs
    {
    if (!fatAddr || !fatVal)
        return;
    // Statically-known widening → recv is a code address → never register.
    if (rhs && [self fnSignatureForWidening:rhs.resolvedType])
        return;

    XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                  window:XTIRWindowUnbanked];
    XTIRType* ptrPtr = [XTIRType ptrToType:ptrT window:XTIRWindowUnbanked];

    // Register the RECV word (field 0) — the same word truthiness tests, and the
    // same word a `weak:T@` slot holds. That uniformity is the point: the side
    // table zeroes word 0 whatever the slot is, with no kind-tag per node.
    XTIRValue* recvAddr = [self emitFieldAddr:fatAddr fieldIndex:0 resultType:ptrPtr];
    XTIRValue* recv = [self emitInsnOpcode:XTIROpAggExtract
                                    result:ptrT
                                  operands:@[ [XTIROperand useWithValueId:fatVal.valueId],
                                              [XTIROperand immIWithType:[XTIRType u16Type]
                                                                  value:0] ]];
    if (!recvAddr || !recv)
        return;
    XTIRValue* codeAddr = recvAddr; // the slot registered, below

    // Runtime trampoline guard. The static skip above only sees a LITERAL
    // widening; it cannot see through `setAction(weak:act_t^ a) { action = a; }`,
    // where the RHS is a parameter of unknown provenance. But a weak `^` of
    // signature S can only ever carry ONE trampoline — `__bm_tramp_S` — so a
    // single compare settles it exactly.
    //
    // Branchless: register a NULL object when the code word IS that trampoline.
    // The weak runtime already skips a null obj ("null object → nothing to
    // track"), so no entry is made. Without this, a widened `^` would burn one
    // of the bounded (64 by default) weak slots FOREVER — nothing ever dies at
    // a `.text` address, so the entry could never fire.
    XTIRValue* objToRegister = recv;
    XTFunctionType* sig = (XTFunctionType*)boundType.boundMethodSignature;
    NSString* tname = sig ? [self boundTrampolineForSignature:sig] : nil;
    XTIRSymbol* tsym = tname ? [self.module symbolForName:tname] : nil;
    if (tsym)
        {
        XTIRValue* code = [self emitInsnOpcode:XTIROpAggExtract
                                        result:ptrT
                                      operands:@[ [XTIROperand useWithValueId:fatVal.valueId],
                                                  [XTIROperand immIWithType:[XTIRType u16Type]
                                                                      value:1] ]];
        XTIRSymbolId tid = [self.module.symbols indexOfObjectIdenticalTo:tsym];
        XTIRValue* trampAddr = [self emitInsnOpcode:XTIROpAddrOf
                                             result:ptrT
                                           operands:@[ [XTIROperand symWithSymbolId:tid] ]];
        if (code && trampAddr)
            {
            XTIRValue* isTramp = [self allocateValueOfType:[XTIRType boolType]
                                                    atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                             result:isTramp
                                                           operands:@[ [XTIROperand useWithValueId:code.valueId],
                                                                       [XTIROperand useWithValueId:trampAddr.valueId] ]
                                                          predicate:XTIRICmpEQ
                                                             dbgLoc:nil]];
            XTIRValue* nullObj = [self allocateValueOfType:ptrT atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                             result:nullObj
                                                           operands:@[ [XTIROperand immIWithType:ptrT value:0] ]
                                                             dbgLoc:nil]];
            XTIRValue* sel = [self allocateValueOfType:ptrT atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                             result:sel
                                                           operands:@[ [XTIROperand useWithValueId:isTramp.valueId],
                                                                       [XTIROperand useWithValueId:nullObj.valueId],
                                                                       [XTIROperand useWithValueId:recv.valueId] ]
                                                             dbgLoc:nil]];
            objToRegister = sel;
            }
        }

    [self emitWeakUnregisterSlot:codeAddr];
    [self emitWeakRegisterSlot:codeAddr obj:objToRegister];
    }

/****************************************************************************\
|* Register a WEAK LOCAL in the side table, so it auto-zeroes when its target
|* dies. Covers both `weak:T@` and a bound method (`^`).
|*
|* Locals were never registered at all — `weak:` on a local was silently a
|* no-op, and a `^` local inherited that. The consequence for a `^` is a silent
|* USE-AFTER-FREE, because the truth test cannot see it:
|*
|*     act_t^ a = &c.onClick;
|*     ... c dies ...
|*     if (a) { a(); }        // TESTS TRUE. Calls through freed memory.
|*
|* `if (a)` tests the CODE word, and the code stays valid forever — only recv is
|* dead. So the one guard a careful programmer writes passes.
|*
|* The local must be PINNED for this to work (see collectStructLocalDeclsIn:):
|* the table zeroes the slot's MEMORY, which an SSA copy would never observe.
\****************************************************************************/
- (void)emitWeakLocalRegisterNamed:(NSString*)name
                             value:(XTIRValue*)val
                           rhsNode:(nullable XTASTNode*)rhs
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!pl)
        return;
    XTType* ty = self.pinnedLocalASTType[name];
    if (!ty)
        return;
    // Decide BEFORE emitting anything: every other pinned local (a struct, an
    // array) would otherwise pick up a dead AddrOf.
    BOOL isBound = ty.boundMethodSignature != nil;
    BOOL isWeakP = [self astTypeIsWeakClassPointer:ty];
    if (!isBound && !isWeakP)
        return;
    // A statically-known widening (`callback f(i32); f = triple;`) puts a CODE
    // address in recv, so there is nothing that can ever die and nothing to
    // register. emitWeakBoundRegisterAt: already returns early for it — but it
    // does so AFTER this method has materialised the slot address, and that
    // address is then used by nobody. The store above computed its own; this
    // one existed only for a registration that does not happen.
    //
    // Same reason as the guard directly above, one case further in: decide
    // before emitting, because an AddrOf + FieldAddr nothing consumes is dead
    // code at every such assignment. It made callback_shapes.xc the one red
    // fixture in the matrix — irwide, and xcc-diff on arm64/android/xt6502 —
    // because the ported front end (correctly) emits neither instruction.
    if (isBound && rhs && [self fnSignatureForWidening:rhs.resolvedType])
        return;

    // Weak local: the payload sits past two hidden link words. See pinnedAddr:.
    XTIRType* ptrTy = nil;
    XTIRValue* slotAddr = [self pinnedAddr:pl name:name outType:&ptrTy];
    if (!slotAddr)
        return;

    if (isBound)
        {
        // A `^`: register the CODE word against recv, with the trampoline guard.
        [self emitWeakBoundRegisterAt:slotAddr value:val boundType:ty rhsNode:rhs];
        return;
        }
    [self emitWeakUnregisterSlot:slotAddr];
    [self emitWeakRegisterSlot:slotAddr obj:val];
    }

/****************************************************************************\
|* Enrol a weak local in the ARC scope so scope-exit teardown drops its
|* side-table entry.
|*
|* MUST be called where the local is DECLARED, not where it is assigned. A local
|* declared in an outer scope but assigned inside an inner one would otherwise be
|* enrolled in the INNER scope — so its entry was unregistered at the inner
|* scope's exit, BEFORE the referent it points at was released there. The entry
|* was gone by the time the object died, so nothing zeroed the slot and the weak
|* reference dangled. (It passed only by accident while register/unregister used
|* different addresses and the unregister silently missed.)
\****************************************************************************/
/****************************************************************************\
|* Enrol a local in the CURRENT ARC scope frame, once.
|*
|* The frame is a list of NAMES and the teardown releases `self.locals[name]`
|* for each entry — so the same name twice is the same VALUE released twice.
|* That is not hypothetical: a C-style `for` pushes no scope of its own, so two
|* loops in one function that both declare `Leaf@ c` enrol "c" twice in the
|* enclosing frame, and every teardown after the second loop released its
|* binding twice. The victim is a BORROWED object (a list element, a child
|* node) whose real owner still holds it, so nothing goes wrong until the
|* allocator hands the block to someone else — which is why the self-hosted
|* front end died in an unrelated downcast, three phases away from the cause.
|* (private:docs/bugs/024.)
|*
|* Dedup is against the TOP frame only: a genuinely shadowed name in an inner
|* scope belongs to a different frame and is a different binding.
\****************************************************************************/
- (void)enrollInArcScope:(NSString*)name
    {
    NSMutableArray<NSString*>* frame = self.arcScopeStack.lastObject;
    if (!frame || [frame containsObject:name])
        return;
    [frame addObject:name];
    }

- (void)noteWeakPinnedLocal:(NSString*)name
    {
    if (!self.pinnedLocals[name])
        return;
    XTType* ty = self.pinnedLocalASTType[name];
    if (!ty)
        return;
    if (ty.boundMethodSignature == nil && ![self astTypeIsWeakClassPointer:ty])
        return;
    if ([self.weakPinnedLocals containsObject:name])
        return;
    [self.weakPinnedLocals addObject:name];
    [self enrollInArcScope:name];
    }

// Drop a weak local's side-table entry at scope exit — its frame slot is about
// to be reused, and a stale entry would let a later dealloc write through it.
- (void)emitWeakLocalUnregisterNamed:(NSString*)name
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    XTType* ty = pl ? self.pinnedLocalASTType[name] : nil;
    if (!ty)
        return;
    if (ty.boundMethodSignature == nil && ![self astTypeIsWeakClassPointer:ty])
        return;
    // Weak local: the payload sits past two hidden link words. See pinnedAddr:.
    XTIRType* ptrTy = nil;
    XTIRValue* slotAddr = [self pinnedAddr:pl name:name outType:&ptrTy];
    if (slotAddr)
        [self emitWeakUnregisterSlot:slotAddr];
    }

/****************************************************************************\
|* Is this AST type a WEAK SLOT — i.e. storage that must be linked into the
|* referent's chain so it auto-zeroes when the referent dies?
|*
|* Both `weak:T@` and a bound method (`^`, which is always auto-zeroing when
|* stored) qualify. See private:docs/Design/weak-refs-intrusive.md.
\****************************************************************************/
- (BOOL)astTypeIsWeakSlot:(nullable XTType*)ty
    {
    if (!ty)
        return NO;
    return ty.boundMethodSignature != nil || [self astTypeIsWeakClassPointer:ty];
    }

/****************************************************************************\
|* Append the two hidden LINK fields that precede a weak slot's payload, and
|* return the bytes consumed.
|*
|* The links go BEFORE the payload, and the slot's recorded field index points at
|* the PAYLOAD — so every existing load/store of the field works completely
|* unchanged, while the runtime finds the links at a fixed negative offset from
|* the slot address:
|*
|*     slot[-2] = prev      slot[-1] = next      slot[0] = referent
|*
|* That offset is the same for a `weak:T@` (payload = the referent) and for a
|* `^` (payload = {recv, code}, and recv IS the referent — see phase-599), which
|* is what makes the runtime walk uniform with no kind-tag per node.
\****************************************************************************/
- (uint32_t)appendWeakLinkFieldsTo:(NSMutableArray<XTIRLayoutField*>*)fields
                          atOffset:(uint32_t)off
                        fieldIndex:(NSUInteger*)fieldIndex
    {
    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    // The AST pointer width, NOT XTIRType.byteWidth — every other offset in this
    // layout is computed from AST widths, and Ptr(Void)'s IR byteWidth is 0, so
    // using it silently stacked all three fields at the same offset.
    uint32_t w = (uint32_t)[XTPointerType pointerToType:[XTType u8Type]].byteWidth;
    [fields addObject:[[XTIRLayoutField alloc] initWithOffset:off type:linkTy]];
    (*fieldIndex)++;
    [fields addObject:[[XTIRLayoutField alloc] initWithOffset:off + w type:linkTy]];
    (*fieldIndex)++;
    return 2 * w;
    }

// The slot type for a weak local: Agg[prev, next, payload]. Links FIRST, so the
// payload sits at the same negative offset from the links as a weak ivar's does
// and the runtime walk is uniform. See private:docs/Design/weak-refs-intrusive.md.
- (XTIRType*)weakSlotAggFor:(XTIRType*)payload
    {
    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    uint32_t w = (uint32_t)[XTPointerType pointerToType:[XTType u8Type]].byteWidth;
    // XTIRType.byteWidth is 0 for a Ptr, so the payload's width must come from
    // the AST pointer width (a weak payload is a pointer) or the aggregate's own
    // layout size (a `^`). Getting this wrong silently under-sized the frame slot.
    uint32_t pw = (payload.kind == XTIRTypeKindAgg && payload.layout)
                      ? (uint32_t)payload.layout.size
                      : w;
    XTIRLayout* lay = [[XTIRLayout alloc]
        initWithSize:(2 * w + pw)
           alignment:1
              fields:@[ [[XTIRLayoutField alloc] initWithOffset:0 type:linkTy],
                        [[XTIRLayoutField alloc] initWithOffset:w
                                                           type:linkTy],
                        [[XTIRLayoutField alloc] initWithOffset:2 * w
                                                           type:payload] ]];
    // Register it, or it prints as Agg(?) and cannot survive the IR-text
    // round-trip through the back-end process.
    [self.module addLayout:lay];
    return [XTIRType aggWithLayout:lay];
    }

// The PAYLOAD address of a pinned local — the address every load/store of the
// local must use. For a weak slot that is field 2 (past the two link words);
// for anything else it is just the slot address.
- (nullable XTIRValue*)payloadAddrForPinnedLocal:(NSString*)name
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!pl)
        return nil;
    XTIRType* ptrTy = [XTIRType ptrToType:pl.type window:XTIRWindowUnbanked];
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:ptrTy
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base)
        return nil;
    XTType* ast = self.pinnedLocalASTType[name];
    if (![self astTypeIsWeakSlot:ast])
        return base;
    XTIRType* payload = pl.type.layout.fields.lastObject.type;
    XTIRType* payloadPtr = [XTIRType ptrToType:payload window:XTIRWindowUnbanked];
    return [self emitFieldAddr:base fieldIndex:2 resultType:payloadPtr];
    }

/****************************************************************************\
|* Address of a pinned local's PAYLOAD, plus the payload's IR type.
|*
|* A WEAK local's slot is Agg[prev, next, payload] — the two link words come
|* first, so the runtime finds them at the same negative offset it uses for a
|* weak ivar. Every load/store of a pinned local must therefore go through here,
|* or it would read/write the LINKS instead of the value.
|*
|* For every other pinned local this is just AddrOf(pl), unchanged.
\****************************************************************************/
- (nullable XTIRValue*)pinnedAddr:(XTIRPinnedLocal*)pl
                             name:(NSString*)name
                          outType:(XTIRType**)outTy
    {
    BOOL weak = [self astTypeIsWeakSlot:self.pinnedLocalASTType[name]];
    XTIRType* payload = weak ? pl.type.layout.fields.lastObject.type : pl.type;
    if (outTy)
        *outTy = payload;
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:[XTIRType ptrToType:pl.type
                                                        window:XTIRWindowUnbanked]
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base || !weak)
        return base;
    return [self emitFieldAddr:base
                    fieldIndex:2
                    resultType:[XTIRType ptrToType:payload
                                            window:XTIRWindowUnbanked]];
    }

/****************************************************************************\
|* Zero a weak LOCAL's two link words at its declaration.
|*
|* An object's ivars are zero-initialised by `new`, so a weak IVAR's links start
|* null for free. A local's frame slot is NOT zeroed — it is whatever the last
|* call left there — so its links would start as garbage, and the very first
|* unregister would follow a garbage `pprev` and write through it. (It
|* segfaulted.)
\****************************************************************************/
- (void)emitWeakLinkInitForLocalNamed:(NSString*)name
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!pl)
        return;
    if (![self astTypeIsWeakSlot:self.pinnedLocalASTType[name]])
        return;

    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    XTIRType* linkPtr = [XTIRType ptrToType:linkTy window:XTIRWindowUnbanked];
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:[XTIRType ptrToType:pl.type
                                                        window:XTIRWindowUnbanked]
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base)
        return;
    XTIRValue* zero = [self allocateValueOfType:linkTy atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:linkTy value:0] ]
                                                     dbgLoc:nil]];
    for (NSUInteger f = 0; f < 2; f++)
        {
        XTIRValue* fa = [self emitFieldAddr:base fieldIndex:f resultType:linkPtr];
        if (fa)
            [self emitStore:fa value:zero];
        }
    }

/****************************************************************************\
|* Address of a GLOBAL's payload, plus the payload's IR type.
|*
|* A weak global's storage is Agg[prev, next, payload] — the link words come
|* first — so every load/store must land past them. For every other global this
|* is just AddrOf(sym), unchanged.
\****************************************************************************/
- (nullable XTIRValue*)globalPayloadAddr:(XTIRSymbol*)sym
                                symbolId:(XTIRSymbolId)sid
                                 outType:(XTIRType**)outTy
    {
    BOOL weak = self.weakGlobals[sym.name] != nil;
    XTIRType* payload = weak ? sym.globalType.layout.fields.lastObject.type
                             : sym.globalType;
    if (outTy)
        *outTy = payload;
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:[XTIRType ptrToType:sym.globalType
                                                        window:XTIRWindowUnbanked]
                                  operands:@[ [XTIROperand symWithSymbolId:sid] ]];
    if (!base || !weak)
        return base;
    return [self emitFieldAddr:base
                    fieldIndex:2
                    resultType:[XTIRType ptrToType:payload
                                            window:XTIRWindowUnbanked]];
    }

/****************************************************************************\
|* Zero the hidden LINK words of every auto-zeroing field in a STRUCT LOCAL.
|*
|* A frame slot is whatever the last call left there, so the links start as
|* garbage and the first unregister follows a garbage `pprev` and writes through
|* it. (An object's ivars are zero-inited by `new`; a frame slot is not.) Same
|* lesson as weak locals and weak array elements.
\****************************************************************************/
- (void)emitStructWeakLinkInitForLocalNamed:(NSString*)name
                                 structType:(XTStructType*)st
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!pl || !st)
        return;
    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    XTIRType* linkPtr = [XTIRType ptrToType:linkTy window:XTIRWindowUnbanked];
    XTIRValue* zero = nil;
    // The slot address is formed ONCE and reused for every field (the port
    // does the same); re-forming it per field left a dead AddrOf and diverged
    // (bug 162 — a struct with 2+ auto-zeroing fields).
    XTIRValue* base = nil;

    for (XTStructField* f in st.fields)
        {
        if (![self astTypeIsWeakSlot:f.fieldType])
            continue;
        NSUInteger idx = 0;
        if (![self structType:st fieldNamed:f.fieldName index:&idx astType:NULL])
            continue;
        if (idx < 2)
            continue;
        if (!zero)
            {
            zero = [self allocateValueOfType:linkTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                             result:zero
                                                           operands:@[ [XTIROperand immIWithType:linkTy
                                                                                           value:0] ]
                                                             dbgLoc:nil]];
            }
        if (!base)
            {
            base = [self emitInsnOpcode:XTIROpAddrOf
                                 result:[XTIRType ptrToType:pl.type
                                                     window:XTIRWindowUnbanked]
                               operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
            }
        if (!base)
            continue;
        for (NSUInteger k = idx - 2; k < idx; k++)
            {
            XTIRValue* fa = [self emitFieldAddr:base fieldIndex:k resultType:linkPtr];
            if (fa)
                [self emitStore:fa value:zero];
            }
        }
    }

// FieldAddr produces a Ptr to the slot's IR type (pure op, no memory).
- (XTIRValue*)emitFieldAddr:(XTIRValue*)basePointer
                 fieldIndex:(NSUInteger)fieldIndex
                 resultType:(XTIRType*)resultPtrType
    {
    return [self emitInsnOpcode:XTIROpFieldAddr
                         result:resultPtrType
                       operands:@[ [XTIROperand useWithValueId:basePointer.valueId],
                                   [XTIROperand immIWithType:[XTIRType u8Type]
                                                       value:(int64_t)fieldIndex] ]];
    }

// Emit a u16 immediate constant into the current block. Used for the
// (count, elemSize) array-cookie args passed to a class allocator.
- (XTIRValue*)emitU16Const:(uint32_t)value
    {
    XTIRType* u16 = [XTIRType u16Type];
    XTIRValue* v = [self allocateValueOfType:u16 atSite:self.currentBlock];
    XTIRInsn* c = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                            result:v
                                          operands:@[ [XTIROperand immIWithType:u16
                                                                          value:(int64_t)value] ]
                                            dbgLoc:nil];
    [self.currentBlock appendInstruction:c];
    return v;
    }

- (void)emitRetain:(XTIRValue*)pointer
    {
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpRetain
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:pointer.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }

- (void)emitRelease:(XTIRValue*)pointer
    {
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpRelease
                                               result:nil
                                             operands:@[ [XTIROperand useWithValueId:pointer.valueId],
                                                         [XTIROperand useWithValueId:self.memToken.valueId] ]
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }

#pragma mark - ARC owned-temporary tracking (task #123)

// Record a freshly-produced +1 class temporary (a `new T` result, or the
// result of a returnsRetained call) so the end-of-full-expression sweep
// releases it unless a strong binding / return consumes it first.
- (void)registerOwnedTemp:(nullable XTIRValue*)v
    {
    if (!v)
        return;
    if (!self.ownedTemps)
        self.ownedTemps = [NSMutableArray array];
    if (!self.ownedTempDepths)
        self.ownedTempDepths = [NSMutableArray array];
    if (!self.ownedTempBlocks)
        self.ownedTempBlocks = [NSMutableArray array];
    [self.ownedTemps addObject:v];
    [self.ownedTempDepths addObject:@(self.condDepth)];
    [self.ownedTempBlocks addObject:self.currentBlock ?: (id)[NSNull null]];
    }

// A strong binding (var-decl init, assignment to a strong slot) or a
// return takes ownership of `v` — drop it from the pending sweep.
- (void)consumeOwnedTemp:(nullable XTIRValue*)v
    {
    if (!v || !self.ownedTemps)
        return;
    NSUInteger idx = [self.ownedTemps indexOfObjectIdenticalTo:v];
    if (idx == NSNotFound)
        return;
    [self.ownedTemps removeObjectAtIndex:idx];
    if (idx < self.ownedTempDepths.count)
        [self.ownedTempDepths removeObjectAtIndex:idx];
    if (idx < self.ownedTempBlocks.count)
        [self.ownedTempBlocks removeObjectAtIndex:idx];
    }

// ARC ownership follows a value through a no-op reinterpretation (a pointer
// Bitcast / IntToPtr — e.g. an upcast `(P@)new C()` to a protocol pointer):
// the cast yields a NEW IR value, so move the pending owned-temp registration
// onto it (keeping its conditional depth). Without this the ORIGINAL temp stays
// pending and gets released, while the returned/bound cast result is what's
// actually live — freeing the object out from under its owner. Same fix the
// `coerceValue:` path already applies for width coercions.
- (void)retargetOwnedTempFrom:(nullable XTIRValue*)src to:(nullable XTIRValue*)result
    {
    if (!src || !result || result == src || self.ownedTemps.count == 0)
        return;
    NSUInteger idx = [self.ownedTemps indexOfObjectIdenticalTo:src];
    if (idx == NSNotFound)
        return;
    self.ownedTemps[idx] = result;
    }

// Widen/narrow each entry of `args` (the method-call args, self excluded) to the
// matching parameter type of the protocol method `node` dispatches to. Mirrors
// the width/sign coercion the concrete-callee paths apply via `sym.function
// .paramTypes`; a protocol dispatch has no concrete callee, so the param types
// come from the protocol declaration. No-op if the protocol/method isn't found.
- (void)coerceArgs:(NSMutableArray<XTIRValue*>*)args
    toProtocolMethodOf:(XTMethodCallExprNode*)node
    {
    XTProtocolDeclNode* proto = self.protocolDeclsByName[node.resolvedProtocolName];
    if (!proto)
        return;
    XTMethodDeclNode* pm = nil;
    for (XTMethodDeclNode* m in proto.methods)
        {
        if ([m.methodName isEqualToString:node.methodName] && m.parameters.count == node.arguments.count)
            {
            pm = m;
            break;
            }
        }
    if (!pm)
        return;
    for (NSUInteger k = 0; k < args.count && k < pm.parameters.count && k < node.arguments.count; k++)
        {
        XTType* dstAST = pm.parameters[k].paramType;
        XTType* srcAST = [node.arguments[k] resolvedType];
        if (!dstAST || !srcAST)
            continue;
        // Pointers/aggregates are passed as-is (a `^`/`@` arg needs no int ext);
        // only scalar integer width/sign differences need a cast.
        if (dstAST.kind == XTTypeKindPointer || dstAST.kind == XTTypeKindStruct || dstAST.kind == XTTypeKindVoid)
            continue;
        XTIRType* dstIR = [self irTypeForASTType:dstAST at:node.location];
        if (!dstIR || dstIR.kind == XTIRTypeKindPtr || dstIR.kind == XTIRTypeKindAgg || dstIR.kind == XTIRTypeKindVoid)
            continue;
        NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
        BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
        if (srcW == dstW && srcSgn == dstSgn)
            continue;
        XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                        : dstW < srcW ? XTIROpTrunc
                                      : XTIROpBitcast;
        XTIRValue* cv = [self emitInsnOpcode:op
                                      result:dstIR
                                    operands:@[ [XTIROperand useWithValueId:((XTIRValue*)args[k]).valueId] ]];
        if (cv)
            args[k] = cv;
        }
    }

// Does an RHS / initialiser expression yield a BORROWED (+0) class
// pointer? Then the strong slot it binds must RETAIN it. id / member /
// cast references and calls to non-returnsRetained functions (e.g.
// Map.get) are borrowed; a `new T` or a returnsRetained call is +1 — NOT
// borrowed — and the slot instead adopts the owned temp (no retain, and
// the temp is consumed from the end-of-full-expression sweep). (#123)
- (BOOL)arcRhsIsBorrowed:(nullable XTASTNode*)rhs
    {
    if (!rhs)
        return NO;
    switch (rhs.nodeKind)
        {
    // The ONLY +1 producers. `new T` hands back an owned temporary, and a
    // returnsRetained call does the same — the strong slot ADOPTS those (no retain;
    // the temp is consumed from the end-of-full-expression sweep).
    case XTASTNodeKindNewExpr:
        return NO;
    // A CAST is transparent to ownership: `(Number@ ?)m.get(k)` is as owned
    // as `m.get(k)` is. Treating every cast as borrowed made a strong local
    // retain on top of the call's +1 — a leak while calls were mostly +0,
    // and a double-count the moment every class-pointer return became +1.
    // The failable downcast retargets the owned temp onto its result
    // (lowerClassDowncastFrom:), so the temp really is the cast's value.
    case XTASTNodeKindCastExpr:
        return [self arcRhsIsBorrowed:((XTCastExprNode*)rhs).operand];
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* c = (XTCallExprNode*)rhs;
        // A `^` call is +1 by convention (it is dynamic, so there is no name
        // to look up) — see the matching note in lowerExpression's CallExpr
        // dispatch. So the slot ADOPTS a bound-call result rather than
        // retaining it; retaining would leak the +1 the call already holds.
        if (c.isBoundCall)
            return NO;
        return ![self astCallYieldsOwnedClassPointer:rhs];
        }
    case XTASTNodeKindMethodCallExpr:
        return ![self astCallYieldsOwnedClassPointer:rhs];
    // EVERYTHING ELSE IS BORROWED, and the default must say so.
    //
    // This used to list Identifier / MemberAccess / CastExpr as borrowed and let
    // every other node kind fall to `default: NO` — which the callers read as
    // "already +1, adopt it without retaining". A TERNARY and a SUBSCRIPT both yield
    // a BORROWED class pointer and both landed there, so
    //
    //     h.o = c ? shared : shared;      // no Retain emitted; refcount stays 1
    //     h.o = (Obj@)0;                  // release-old -> 0 -> FREED
    //
    // freed an object that was still reachable from somewhere else. The next `new`
    // recycled the block and its init zeroed it, so what the user SAW was an Array
    // elsewhere in the object graph silently going empty — the victim nowhere near
    // the cause, which is why it resisted reduction for so long.
    //
    // The default was also backwards in the DANGEROUS direction: getting "borrowed"
    // wrong leaks; getting "owned" wrong frees a live object. Default to borrowed,
    // and list the +1 producers explicitly.
    //
    // A TERNARY is one of them WHEN AN ARM IS (private:docs/bugs/081, found by
    // blewit leaking). Blanket-borrowed is what the note above fixed and it
    // was right for `c ? shared : shared`; it is wrong for
    // `c ? new P() : new P()`, where both arms already delivered +1 and the
    // slot retained on top — leaking the whole object on every evaluation.
    // Either-arm rather than both-arms, because lowerTernaryExpr balances
    // the mixed case: when only one arm owns, the other is retained in its
    // own block so the join is +1 whichever way it went.
    case XTASTNodeKindTernaryExpr:
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)rhs;
        return [self arcRhsIsBorrowed:t.thenExpr] && [self arcRhsIsBorrowed:t.elseExpr];
        }
    default:
        return YES;
        }
    }

// End of a full-expression: release every still-pending owned temp, then
// clear. `startBlock` is the block the full-expression began in.
//
// A temp may only be released here if it is definitely live at this point.
// Two cases qualify:
//
//   * The expression created no control flow at all (currentBlock ==
//     startBlock) — the straight-line case.
//
//   * The temp was created at the SAME conditional-nesting depth as this flush
//     point — i.e. unconditionally relative to here. A static-init guard
//     branches (`__sinit_<C> == 0 ? run : cont`) but rejoins immediately, so it
//     does NOT change depth: `a.add(Number.with(42))` and even
//     `m.set(String.withI32(i), Number.with(i))` — two static factory calls,
//     two guard diamonds — all stay at depth 0, and every pending temp is live
//     at the join.
//
// The depth test replaced an earlier `defSite.block == currentBlock` test,
// which released only the LAST temp when several static calls each split the
// block: the first call's temp ended up in an earlier (dominating) block and
// was dropped. `m.set(a, b)` with two `+1` arguments leaked one of them — which
// is every populated Map.
//
// A temp created at a DEEPER depth (inside a ternary / short-circuit arm) may
// be live on only one path, so it is still dropped untracked rather than risk
// an unbalanced release.
// Release (and forget) every pending owned temp recorded at `depth`. Used by
// the short-circuit arms, where the arm's own value is a Bool and so cannot be
// one of them; the end-of-expression sweep would otherwise drop them untracked
// and leak. NOT used by the ternary arms — there the arm's value MAY be the
// temp, and releasing it would free the expression's own result.
- (void)releaseOwnedTempsAtDepth:(NSInteger)depth
    {
    if (self.ownedTemps.count == 0)
        return;
    if (self.currentBlock.terminator != nil)
        return; // nowhere to put them
    for (NSInteger i = (NSInteger)self.ownedTemps.count - 1; i >= 0; i--)
        {
        NSInteger d = ((NSUInteger)i < self.ownedTempDepths.count)
                          ? self.ownedTempDepths[(NSUInteger)i].integerValue
                          : self.condDepth;
        if (d != depth)
            continue;
        [self emitRelease:self.ownedTemps[(NSUInteger)i]];
        [self.ownedTemps removeObjectAtIndex:(NSUInteger)i];
        if ((NSUInteger)i < self.ownedTempDepths.count)
            [self.ownedTempDepths removeObjectAtIndex:(NSUInteger)i];
        if ((NSUInteger)i < self.ownedTempBlocks.count)
            [self.ownedTempBlocks removeObjectAtIndex:(NSUInteger)i];
        }
    }

- (void)flushOwnedTempsFrom:(XTIRBlock*)startBlock
    {
    if (self.ownedTemps.count == 0)
        return;
    // A block that already has a terminator cannot take more instructions —
    // the full-expression ended by branching away (a `return` inside it, say).
    // Nothing can be released here; drop the temps untracked as before.
    if (self.currentBlock.terminator == nil)
        {
        for (NSUInteger i = 0; i < self.ownedTemps.count; i++)
            {
            NSInteger d = (i < self.ownedTempDepths.count)
                              ? self.ownedTempDepths[i].integerValue
                              : self.condDepth;
            // …or the temp was CREATED in the block we are about to emit
            // into. That block dominates itself, so the release is always
            // reachable — and it is the case a static call produces, because
            // its init guard splits the block between startBlock and here.
            // Without it, `printf("%@", obj.child())` leaked the child on
            // every call (bug 037): a variadic callee is a static method, so
            // every such argument went through a split block.
            id defBlk = (i < self.ownedTempBlocks.count) ? self.ownedTempBlocks[i] : nil;
            BOOL bornHere = (defBlk && defBlk != (id)[NSNull null] && defBlk == self.currentBlock);
            if (self.currentBlock == startBlock || d == self.condDepth || bornHere)
                [self emitRelease:self.ownedTemps[i]];
            }
        }
    [self.ownedTemps removeAllObjects];
    [self.ownedTempDepths removeAllObjects];
    [self.ownedTempBlocks removeAllObjects];
    }

#pragma mark - Symbol-table lazy lookups

// Look up (or create) a runtime-helper symbol with the given name.
// Used by `new` lowering for `_xtc_new_<Class>`.
- (XTIRSymbolId)runtimeHelperSymbolNamed:(NSString*)name
    {
    XTIRSymbol* sym = [self.module symbolForName:name];
    if (!sym)
        {
        sym = [XTIRSymbol runtimeHelperWithName:name
                                     clobberSet:[[XTIRClobberSet alloc] initWithClobberedNames:@[]]
                                       mayAlloc:YES
                                       mayThrow:NO];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, @"variadic" : @NO};
        [self.module addSymbol:sym];
        }
    return [self.module.symbols indexOfObjectIdenticalTo:sym];
    }

#pragma mark - Expression dispatch

- (nullable XTIRValue*)lowerExpression:(XTASTNode*)node
    {
    if (self.aborted)
        return nil;
    switch (node.nodeKind)
        {
    case XTASTNodeKindLiteralInt:
        return [self lowerLiteralInt:(XTLiteralIntNode*)node];
    case XTASTNodeKindLiteralFloat:
        return [self lowerLiteralFloat:(XTLiteralFloatNode*)node];
    case XTASTNodeKindLiteralString:
        return [self lowerLiteralString:(XTLiteralStringNode*)node];
    case XTASTNodeKindLiteralBool:
        return [self lowerLiteralBool:(XTLiteralBoolNode*)node];
    case XTASTNodeKindLiteralChar:
        return [self lowerLiteralChar:(XTLiteralCharNode*)node];
    case XTASTNodeKindIdentifier:
        return [self lowerIdentifier:(XTIdentifierNode*)node];
    case XTASTNodeKindBinaryExpr:
        return [self lowerBinaryExpr:(XTBinaryExprNode*)node];
    case XTASTNodeKindUnaryExpr:
        return [self lowerUnaryExpr:(XTUnaryExprNode*)node];
    case XTASTNodeKindAssignExpr:
        return [self lowerAssignExpr:(XTAssignExprNode*)node];
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* c = (XTCallExprNode*)node;
        XTIRValue* r = [self lowerCallExpr:c];
        // Every call yielding a class pointer yields it at +1, so its
        // result is an owned temporary to release at end-of-full-expression
        // (#123, #829). That includes a call through a bound method (`^`),
        // which is DYNAMIC and has no mangled name to classify: a `^`
        // returns an object the same way any function does, owned.
        if (r && [self irValueIsPointer:r] && [self astCallYieldsOwnedClassPointer:node])
            [self registerOwnedTemp:r];
        return r;
        }
    case XTASTNodeKindCastExpr:
        return [self lowerCastExpr:(XTCastExprNode*)node];
    case XTASTNodeKindMemberAccess:
        return [self lowerMemberAccess:(XTMemberAccessNode*)node];
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)node;
        XTIRValue* r = [self lowerMethodCallExpr:m];
        if (r && [self irValueIsPointer:r] && [self astCallYieldsOwnedClassPointer:node])
            [self registerOwnedTemp:r];
        return r;
        }
    case XTASTNodeKindNewExpr:
        return [self lowerNewExpr:(XTNewExprNode*)node];
    case XTASTNodeKindPostfixExpr:
        return [self lowerPostfixExpr:(XTPostfixExprNode*)node];
    case XTASTNodeKindSubscriptExpr:
        return [self lowerSubscriptExpr:(XTSubscriptExprNode*)node];
    case XTASTNodeKindTernaryExpr:
        return [self lowerTernaryExpr:(XTTernaryExprNode*)node];
    case XTASTNodeKindSizeofExpr:
        return [self lowerSizeofExpr:(XTSizeofExprNode*)node];
    default:
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unsupported expression kind %ld", (long)node.nodeKind]];
        return nil;
        }
    }

#pragma mark - Literal / identifier

- (nullable XTIRValue*)lowerLiteralInt:(XTLiteralIntNode*)node
    {
    XTIRType* ty = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!ty)
        return nil;
    XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ [XTIROperand immIWithType:ty value:node.intValue] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

- (nullable XTIRValue*)lowerLiteralFloat:(XTLiteralFloatNode*)node
    {
    XTIRType* ty = [self irTypeForASTType:node.resolvedType at:node.location];
    BOOL isDouble = (node.floatData.length == 8);
    if (!ty)
        {
        ty = isDouble ? [XTIRType f64Type] : [XTIRType f32Type];
        }
    // Format-neutral Const: the IR carries the literal's abstract numeric
    // value (raw IEEE-754 double bits), NOT a backend-specific encoding. The
    // lexer stores the literal as IEEE bytes, so this is a widening read, not
    // a decode — 4 bytes for a single, 8 for a double.
    double value = [XTFloatEncoding doubleFromIEEEData:node.floatData];
    uint64_t raw = 0;
    memcpy(&raw, &value, sizeof(raw));
    XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ [XTIROperand immFWithType:ty rawBytes:raw] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

// Intern a C string and yield its ADDRESS. Factored out of lowerLiteralString
// so the bounds check can emit a site string through the same pooling — two
// identical sites share one symbol, which is what keeps a checked build's
// growth in DATA rather than in code.
- (nullable XTIRValue*)internCString:(NSString*)str
    {
    NSData* utf8 = [str dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData* bytes = [NSMutableData dataWithData:utf8];
    uint8_t nul = 0;
    [bytes appendBytes:&nul length:1];
    NSData* key = [bytes copy];
    NSNumber* cached = self.stringLiterals[key];
    XTIRSymbolId sid;
    if (cached)
        {
        sid = cached.unsignedIntegerValue;
        }
    else
        {
        NSString* name = [NSString stringWithFormat:@"str_%lu",
                                                    (unsigned long)self.stringLiterals.count];
        XTIRSymbol* sym = [XTIRSymbol stringLitWithName:name bytes:key];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        sid = [self.module addSymbol:sym];
        self.stringLiterals[key] = @(sid);
        }
    XTIRType* ptrTy = [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked];
    return [self emitInsnOpcode:XTIROpAddrOf
                         result:ptrTy
                       operands:@[ [XTIROperand symWithSymbolId:sid] ]];
    }

/****************************************************************************\
|* A checked build's bounds check: `_xt_check_bounds(ptr, index, site)`.
|*
|* A CALL, not an inline compare-and-branch. The limit lives in the allocation
|* header, so an inline form still needs the load and then the trap call anyway
|* — one `bl` is fewer bytes at the site, and a checked build is optimising for
|* size and simplicity there, not speed.
|*
|* Emitted in the IR, BEFORE the optimiser, so a later pass can eliminate the
|* ones it can prove redundant, and so one implementation covers every native
|* back end rather than each one growing its own.
\****************************************************************************/
// A FIXED-SIZE array — a local or a global — carries no allocation header, so
// the header-reading check above finds no magic word and returns without
// looking at anything. Every `u32 a[8]; a[9] = x;` therefore passed a checked
// build in silence, which is the half of the feature that would have caught an
// application's global-array overrun. The count is known here at compile time,
// so pass it and let the runtime compare against that instead.
- (void)emitBoundsCheckArray:(XTIRValue*)ptr
                       index:(XTIRValue*)idx
                       count:(NSUInteger)count
                          at:(XTSourceLocation*)loc
    {
    if (!self.boundsCheck || !ptr || !idx || count == 0)
        return;
    NSString* site = [NSString stringWithFormat:@"%@:%lu:%lu",
                                                loc.filename.lastPathComponent ?: @"?",
                                                (unsigned long)loc.line, (unsigned long)loc.column];
    XTIRValue* siteVal = [self internCString:site];
    if (!siteVal)
        return;
    XTIRType* u64 = [XTIRType u64Type];
    XTIRValue* cnt = [self emitInsnOpcode:XTIROpConst
                                   result:u64
                                 operands:@[ [XTIROperand immIWithType:u64 value:(int64_t)count] ]];
    XTIRSymbolId sid = [self runtimeHelperSymbolNamed:@"_xt_check_bounds_n"];
    [self emitCall:sid
          callConv:[XTIRCallConv standard]
         argValues:@[ ptr, idx, cnt, siteVal ]
        resultType:nil];
    }

- (void)emitBoundsCheckPtr:(XTIRValue*)ptr
                     index:(XTIRValue*)idx
                        at:(XTSourceLocation*)loc
    {
    if (!self.boundsCheck || !ptr || !idx)
        return;
    NSString* site = [NSString stringWithFormat:@"%@:%lu:%lu",
                                                loc.filename.lastPathComponent ?: @"?",
                                                (unsigned long)loc.line, (unsigned long)loc.column];
    XTIRValue* siteVal = [self internCString:site];
    if (!siteVal)
        return;
    XTIRSymbolId sid = [self runtimeHelperSymbolNamed:@"_xt_check_bounds"];
    [self emitCall:sid
          callConv:[XTIRCallConv standard]
         argValues:@[ ptr, idx, siteVal ]
        resultType:nil];
    }

- (nullable XTIRValue*)lowerLiteralString:(XTLiteralStringNode*)node
    {
    NSData* utf8 = [node.stringValue dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData* bytes = [NSMutableData dataWithData:utf8];
    uint8_t nul = 0;
    [bytes appendBytes:&nul length:1];
    NSData* key = [bytes copy];
    NSNumber* cached = self.stringLiterals[key];
    XTIRSymbolId sid;
    if (cached)
        {
        sid = cached.unsignedIntegerValue;
        }
    else
        {
        NSString* name = [NSString stringWithFormat:@"str_%lu",
                                                    (unsigned long)self.stringLiterals.count];
        XTIRSymbol* sym = [XTIRSymbol stringLitWithName:name bytes:key];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        sid = [self.module addSymbol:sym];
        self.stringLiterals[key] = @(sid);
        }
    XTIRType* ptrTy = [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked];
    return [self emitInsnOpcode:XTIROpAddrOf
                         result:ptrTy
                       operands:@[ [XTIROperand symWithSymbolId:sid] ]];
    }

// Shared string-literal emission used by lowerLiteralString and by the
// printf-format-rewriting paths (`%e` → `%s` rewrites the format literal
// at the call site, requiring a fresh string constant; the per-enum
// member-name strings emitted for `%e` lookups also go through here so
// identical names dedupe via the same stringLiterals cache).
- (XTIRValue*)emitStringConstant:(NSString*)content
    {
    NSData* utf8 = [content dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData* bytes = [NSMutableData dataWithData:utf8];
    uint8_t nul = 0;
    [bytes appendBytes:&nul length:1];
    NSData* key = [bytes copy];
    NSNumber* cached = self.stringLiterals[key];
    XTIRSymbolId sid;
    if (cached)
        {
        sid = cached.unsignedIntegerValue;
        }
    else
        {
        NSString* name = [NSString stringWithFormat:@"str_%lu",
                                                    (unsigned long)self.stringLiterals.count];
        XTIRSymbol* sym = [XTIRSymbol stringLitWithName:name bytes:key];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        sid = [self.module addSymbol:sym];
        self.stringLiterals[key] = @(sid);
        }
    XTIRType* ptrTy = [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked];
    return [self emitInsnOpcode:XTIROpAddrOf
                         result:ptrTy
                       operands:@[ [XTIROperand symWithSymbolId:sid] ]];
    }

- (nullable XTIRValue*)lowerLiteralBool:(XTLiteralBoolNode*)node
    {
    XTIRType* ty = [XTIRType boolType];
    XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ [XTIROperand immIWithType:ty
                                                                             value:node.boolValue ? 1 : 0] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

- (nullable XTIRValue*)lowerLiteralChar:(XTLiteralCharNode*)node
    {
    XTIRType* ty = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!ty)
        ty = [XTIRType u8Type];
    XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ [XTIROperand immIWithType:ty value:node.charValue] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

- (nullable XTIRValue*)lowerSizeofExpr:(XTSizeofExprNode*)node
    {
    // sizeof evaluates to the byte width of its OPERAND at compile time; the
    // expression's own type (node.resolvedType) is the u16 the constant is
    // typed as. Reading the width off resolvedType — as this did — meant every
    // sizeof evaluated to sizeof(u16) == 2: sizeof(u8), sizeof(u32) and
    // sizeof(some_struct) all came back as 2.
    XTType* resolved = node.resolvedType;
    if (!resolved)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: sizeof without resolved type"];
        return nil;
        }
    // The operand is an XTType for `sizeof(T)`, an expression for `sizeof(e)`.
    id operand = node.operand;
    XTType* measured = nil;
    if ([operand isKindOfClass:[XTType class]])
        measured = operand;
    else if ([operand isKindOfClass:[XTASTNode class]])
        measured = ((XTASTNode*)operand).resolvedType;
    if (!measured)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: sizeof without a resolved operand type"];
        return nil;
        }

    XTIRType* irTy = [self irTypeForASTType:resolved at:node.location];
    if (!irTy)
        return nil;
    XTIRValue* r = [self allocateValueOfType:irTy atSite:self.currentBlock];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ [XTIROperand immIWithType:irTy
                                                                             value:measured.byteWidth] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

- (nullable XTIRValue*)lowerIdentifier:(XTIdentifierNode*)node
    {
    // `self` — the receiver pointer of the enclosing instance method.
    // Sema types it as the current class's self-pointer; the lowering
    // already carries that value in currentSelf (set by _lowerCallable).
    // Lets library methods (e.g. Object.hash / equals) read their own
    // pointer portably instead of via inline 6502 asm (`__self`).
    if ([node.identName isEqualToString:@"self"] && self.currentSelf)
        {
        return self.currentSelf;
        }

    // Stack-allocated (value) class instance — the name evaluates to
    // the ADDRESS of its frame slot, typed as the class self-pointer.
    // This is what lets member access / method dispatch reuse the
    // class-POINTER paths unchanged: `a.legs` FieldAddrs through this
    // pointer, `a.describe()` passes it as self. (A class POINTER local
    // — `Animal@ p = new …` — lives in self.locals and is returned by
    // the SSA path below.)
    XTIRClassInfo* vci = self.valueClassLocals[node.identName];
    if (vci)
        {
        XTIRPinnedLocal* vpl = self.pinnedLocals[node.identName];
        if (vpl)
            {
            return [self emitInsnOpcode:XTIROpAddrOf
                                 result:vci.selfPtrType
                               operands:@[ [XTIROperand useWithValueId:vpl.valueId] ]];
            }
        }

    // Pinned locals (`&x` was taken somewhere) live in a frame
    // slot, not in the SSA locals map. Every read goes through
    // AddrOf + Load — that's what makes the address-taken
    // semantics observable through aliased writes via the pointer.
    //
    // ARRAY-typed pinned locals decay to a pointer to the element
    // type when used by bare name (`Sort.qsort(buf, …)` passes the
    // base address, not the array contents). C-style array decay:
    // the bare name yields `&buf[0]`, NOT the loaded aggregate value,
    // which would push sizeof(buf) bytes into the call frame.
    XTIRPinnedLocal* pl = self.pinnedLocals[node.identName];
    if (pl)
        {
        // Array decay: a bare reference to `u16 buf[N]` lowers to a
        // pointer-to-element, not a Load of the aggregate. Without
        // this `Sort.qsort(buf, …)` would push sizeof(buf) bytes of
        // copied content into the call frame instead of the slot
        // address. Struct-typed pins skip this branch and keep the
        // Load-on-bare-name semantics.
        if ([self.arrayLocalNames containsObject:node.identName])
            {
            XTType* elemAst = self.arrayLocalElementType[node.identName];
            XTIRType* elemIR = elemAst
                                   ? [self irTypeForASTType:elemAst at:node.location]
                                   : nil;
            if (elemIR)
                {
                XTIRType* elemPtrTy = [XTIRType ptrToType:elemIR
                                                   window:XTIRWindowUnbanked];
                return [self emitInsnOpcode:XTIROpAddrOf
                                     result:elemPtrTy
                                   operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                }
            }
        // Weak local: the payload sits past two hidden link words. See pinnedAddr:.
        XTIRType* ptrTy = nil;
        XTIRValue* addr = [self pinnedAddr:pl name:node.identName outType:&ptrTy];
        if (!addr)
            return nil;
        return [self emitLoad:addr pointeeType:ptrTy]; // payload type — see pinnedAddr:
        }

    XTIRValue* v = self.locals[node.identName];
    if (v)
        return v;

    // Inside a method body, a bare identifier may refer to an ivar
    // (sema's class-scope registration makes `x` legal shorthand for
    // `self.x`). Lower it as FieldAddr(self, slot) + Load.
    if (self.currentClassInfo && self.currentSelf)
        {
        NSNumber* slot = nil;
        XTType* ivarAST = nil;
        for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
            {
            slot = ci.ivarFieldIndex[node.identName];
            if (slot)
                {
                ivarAST = ci.ivarASTType[node.identName];
                break;
                }
            }
        if (slot && ivarAST)
            {
            XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:node.location];
            if (!fieldIRType)
                return nil;
            XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType
                                                  window:XTIRWindowUnbanked];
            XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                                     fieldIndex:slot.unsignedIntegerValue
                                     resultType:fieldPtrType];
            return [self emitLoad:fa pointeeType:fieldIRType];
            }
        }

    // Module-level globals — DataGlobal symbol registered in the
    // pre-scan. For scalar (and pointer) globals emit AddrOf + Load
    // so reads always see the live memory value; struct-typed
    // globals don't support a bare value-read (a member-access
    // would handle the field path, returning here only for the
    // never-used "what is the value of the entire struct" case).
    NSNumber* gid = self.globalsByName[node.identName];
    if (gid)
        {
        XTIRSymbol* sym = [self.module symbolForId:gid.unsignedIntegerValue];
        if (!sym)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: global '%@' lost its symbol", node.identName]];
            return nil;
            }
        if (sym.globalType.kind == XTIRTypeKindAgg && !self.weakGlobals[sym.name])
            {
            // Aggregate global (array or struct): emit the address
            // (array-to-pointer decay) rather than trying to load
            // the entire aggregate as a scalar value. The caller
            // (cast, subscript, etc.) will dereference as needed.
            return [self globalPayloadAddr:sym
                                  symbolId:gid.unsignedIntegerValue
                                   outType:NULL];
            }
        // Weak global: payload sits past the hidden link words. See globalPayloadAddr:.
        XTIRType* ptrTy = nil;
        XTIRValue* addr = [self globalPayloadAddr:sym
                                         symbolId:gid.unsignedIntegerValue
                                          outType:&ptrTy];
        if (!addr)
            return nil;
        return [self emitLoad:addr pointeeType:ptrTy];
        }

    // Enum constant (`red`, `yellow`) — a compile-time integer. Emit a
    // Const of the identifier's resolved (enum) IR type; callers coerce as
    // needed (e.g. `u8 v = yellow`).
    NSNumber* ev = self.enumConstants[node.identName];
    if (ev)
        {
        XTIRType* ty = node.resolvedType
                           ? [self irTypeForASTType:node.resolvedType at:node.location]
                           : nil;
        if (!ty || !(XTIRTypeKindIsInteger(ty.kind) || ty.kind == XTIRTypeKindBool))
            ty = [XTIRType u16Type];
        XTIRValue* c = [self allocateValueOfType:ty atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:c
                                                                     operands:@[ [XTIROperand immIWithType:ty value:ev.longLongValue] ]
                                                                       dbgLoc:nil]];
        return c;
        }

    [self softFailLoweringAt:node.location
                 withMessage:[NSString stringWithFormat:
                                           @"lowering: undefined identifier '%@'", node.identName]];
    return nil;
    }

#pragma mark - Binary expressions

static XTIROpcode binaryOpcodeFor(XTBinaryOp op, XTType* resolvedType, BOOL* isCmpOut, uint8_t* predOut)
    {
    BOOL sgn = resolvedType.isSigned;
    if (isCmpOut)
        *isCmpOut = NO;

    // Float arithmetic / comparison — the IR describes the action
    // (FAdd / FCmp); each backend renders it in its own format.
    if (resolvedType && (resolvedType.kind == XTTypeKindFloat || resolvedType.kind == XTTypeKindDouble))
        {
        switch (op)
            {
        case XTBinaryOpAdd:
            return XTIROpFAdd;
        case XTBinaryOpSub:
            return XTIROpFSub;
        case XTBinaryOpMul:
            return XTIROpFMul;
        case XTBinaryOpDiv:
            return XTIROpFDiv;
        case XTBinaryOpEq:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpOEQ;
            return XTIROpFCmp;
        case XTBinaryOpNeq:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpONE;
            return XTIROpFCmp;
        case XTBinaryOpLt:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpOLT;
            return XTIROpFCmp;
        case XTBinaryOpGt:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpOGT;
            return XTIROpFCmp;
        case XTBinaryOpLe:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpOLE;
            return XTIROpFCmp;
        case XTBinaryOpGe:
            if (isCmpOut)
                *isCmpOut = YES;
            if (predOut)
                *predOut = XTIRFCmpOGE;
            return XTIROpFCmp;
        default:
            return XTIROpUnreachable; // float % etc. unsupported
            }
        }

    switch (op)
        {
    case XTBinaryOpAdd:
        return XTIROpAdd;
    case XTBinaryOpSub:
        return XTIROpSub;
    case XTBinaryOpMul:
        return XTIROpMul;
    case XTBinaryOpDiv:
        return sgn ? XTIROpSDiv : XTIROpUDiv;
    case XTBinaryOpMod:
        return sgn ? XTIROpSRem : XTIROpURem;
    case XTBinaryOpBitAnd:
        return XTIROpAnd;
    case XTBinaryOpBitOr:
        return XTIROpOr;
    case XTBinaryOpBitXor:
        return XTIROpXor;
    case XTBinaryOpShl:
        return XTIROpShl;
    case XTBinaryOpShr:
        return sgn ? XTIROpAShr : XTIROpLShr;
    case XTBinaryOpRol:
        return XTIROpRol;
    case XTBinaryOpRor:
        return XTIROpRor;
    case XTBinaryOpEq:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = XTIRICmpEQ;
        return XTIROpICmp;
    case XTBinaryOpNeq:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = XTIRICmpNE;
        return XTIROpICmp;
    case XTBinaryOpLt:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = sgn ? XTIRICmpSLT : XTIRICmpULT;
        return XTIROpICmp;
    case XTBinaryOpGt:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = sgn ? XTIRICmpSGT : XTIRICmpUGT;
        return XTIROpICmp;
    case XTBinaryOpLe:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = sgn ? XTIRICmpSLE : XTIRICmpULE;
        return XTIROpICmp;
    case XTBinaryOpGe:
        if (isCmpOut)
            *isCmpOut = YES;
        if (predOut)
            *predOut = sgn ? XTIRICmpSGE : XTIRICmpUGE;
        return XTIROpICmp;
    default:
        return XTIROpUnreachable;
        }
    }

- (nullable XTIRValue*)lowerBinaryExpr:(XTBinaryExprNode*)node
    {
    if (node.op == XTBinaryOpLogAnd || node.op == XTBinaryOpLogOr)
        {
        return [self lowerShortCircuit:node];
        }

    // Pointer arithmetic (`p + N` / `N + p` / `p - N` where p is
    // a pointer type) routes through ElementAddr, which scales the
    // integer offset by sizeof(pointee) and produces a new pointer
    // of the same type. The verifier's §12.2 type-match check
    // rejects an Add with a Ptr and an integer operand, so this
    // branch has to fire BEFORE the standard widen-then-Add path.
    if (node.op == XTBinaryOpAdd || node.op == XTBinaryOpSub)
        {
        XTType* lt = node.left.resolvedType;
        XTType* rt = node.right.resolvedType;
        BOOL lptr = (lt && lt.kind == XTTypeKindPointer);
        BOOL rptr = (rt && rt.kind == XTTypeKindPointer);
        if (lptr || rptr)
            {
            return [self lowerPtrArithmetic:node];
            }
        }

    XTIRValue* l = [self lowerExpression:node.left];
    XTIRValue* r = [self lowerExpression:node.right];
    if (!l || !r)
        return nil;
    BOOL isCmp = NO;
    uint8_t pred = 0;
    // For arithmetic, both operands must share the result type. For
    // comparisons, both operands must share each other's wider type;
    // the result is Bool.
    XTType* operandASTType;
    if (node.op == XTBinaryOpEq || node.op == XTBinaryOpNeq || node.op == XTBinaryOpLt || node.op == XTBinaryOpGt || node.op == XTBinaryOpLe || node.op == XTBinaryOpGe)
        {
        operandASTType = [XTType widenType:node.left.resolvedType with:node.right.resolvedType];
        }
    else if (node.op == XTBinaryOpShl || node.op == XTBinaryOpShr || node.op == XTBinaryOpRol || node.op == XTBinaryOpRor)
        {
        // Shifts operate at the LEFT operand's promoted type. sema records
        // node.resolvedType = widenType(left,right), which — since a wide shift
        // COUNT (e.g. an i32-promoted `(a*a)&15`) widens the node — can be
        // wider than the left operand; and a narrow assignment context (e.g.
        // `u8 e = (1000 >> 8) & $FF`) can make it NARROWER. Operate at the
        // WIDER of the two: extending the left operand is required so an
        // arithmetic i16→i32 shift sign-extends (xt6502 otherwise zero-extends
        // the high word and drops the sign bit), but the operand must NEVER be
        // truncated below its own width first — `(1000 >> 8)` narrowed to u8
        // would otherwise Trunc 1000→232 BEFORE the shift and yield 0 instead
        // of 3 (the result narrows AFTER the shift, via resultIRType). Keep the
        // LEFT operand's own signedness so AShr/LShr and the SExt/ZExt both key
        // off it, not off the (possibly-unsigned) widened result.
        XTType* lt2 = node.left.resolvedType;
        XTType* resT = node.resolvedType ?: lt2;
        NSUInteger lw = lt2.byteWidth ? lt2.byteWidth : 1;
        NSUInteger rw = resT.byteWidth ? resT.byteWidth : lw;
        NSUInteger w = (lw > rw) ? lw : rw;
        BOOL lsgn = lt2.isSigned;
        XTType* shiftType =
            (w >= 8) ? (lsgn ? [XTType i64Type] : [XTType u64Type]) : (w >= 4) ? (lsgn ? [XTType i32Type] : [XTType u32Type])
                                                                  : (w == 2)   ? (lsgn ? [XTType i16Type] : [XTType u16Type])
                                                                               : (lsgn ? [XTType i8Type] : [XTType u8Type]);
        operandASTType = shiftType;
        l = [self coerceValue:l
                     fromType:lt2
                       toType:shiftType
                     location:node.location];
        r = [self coerceValue:r
                     fromType:node.right.resolvedType
                       toType:[XTType u8Type]
                     location:node.location];
        }
    else
        {
        operandASTType = node.resolvedType;
        }
    if (node.op != XTBinaryOpShl && node.op != XTBinaryOpShr && node.op != XTBinaryOpRol && node.op != XTBinaryOpRor)
        {
        l = [self coerceValue:l
                     fromType:node.left.resolvedType
                       toType:operandASTType
                     location:node.location];
        r = [self coerceValue:r
                     fromType:node.right.resolvedType
                       toType:operandASTType
                     location:node.location];
        }
    // Synthesize rotates from shifts + or so BOTH backends get correct
    // code without dedicated Rol/Ror support (xt6502 emitted JSRs to
    // never-defined _u8Rol routines; arm64 left Rol/Ror unhandled). For
    // a w-bit operand and count n:
    //   x rol n = (x << rn) | (x >>logical ((w-rn)&(w-1))),  rn = n & (w-1)
    //   x ror n = (x >>logical rn) | (x <<       ((w-rn)&(w-1)))
    // Masking BOTH counts with (w-1) makes n==0 and n>=w correct with no
    // shift-by-width (undefined): (w-0)&(w-1) == 0 for power-of-two w.
    // The shift ops already wrap to the operand width on both backends.
    if (node.op == XTBinaryOpRol || node.op == XTBinaryOpRor)
        {
        XTIRType* T = [self irTypeForASTType:operandASTType at:node.location];
        XTIRType* u8T = [XTIRType u8Type];
        if (!T)
            return nil;
        NSUInteger w = operandASTType.byteWidth * 8;
        XTIRValue* wMask = [self emitInsnOpcode:XTIROpConst
                                         result:u8T
                                       operands:@[ [XTIROperand immIWithType:u8T value:(int64_t)(w - 1)] ]];
        XTIRValue* wConst = [self emitInsnOpcode:XTIROpConst
                                          result:u8T
                                        operands:@[ [XTIROperand immIWithType:u8T value:(int64_t)w] ]];
        XTIRValue* rn = [self emitInsnOpcode:XTIROpAnd
                                      result:u8T
                                    operands:@[ [XTIROperand useWithValueId:r.valueId],
                                                [XTIROperand useWithValueId:wMask.valueId] ]];
        XTIRValue* wMinus = [self emitInsnOpcode:XTIROpSub
                                          result:u8T
                                        operands:@[ [XTIROperand useWithValueId:wConst.valueId],
                                                    [XTIROperand useWithValueId:rn.valueId] ]];
        XTIRValue* rev = [self emitInsnOpcode:XTIROpAnd
                                       result:u8T
                                     operands:@[ [XTIROperand useWithValueId:wMinus.valueId],
                                                 [XTIROperand useWithValueId:wMask.valueId] ]];
        XTIROpcode firstOp = (node.op == XTBinaryOpRol) ? XTIROpShl : XTIROpLShr;
        XTIROpcode secondOp = (node.op == XTBinaryOpRol) ? XTIROpLShr : XTIROpShl;
        XTIRValue* part1 = [self emitInsnOpcode:firstOp
                                         result:T
                                       operands:@[ [XTIROperand useWithValueId:l.valueId],
                                                   [XTIROperand useWithValueId:rn.valueId] ]];
        XTIRValue* part2 = [self emitInsnOpcode:secondOp
                                         result:T
                                       operands:@[ [XTIROperand useWithValueId:l.valueId],
                                                   [XTIROperand useWithValueId:rev.valueId] ]];
        return [self emitInsnOpcode:XTIROpOr
                             result:T
                           operands:@[ [XTIROperand useWithValueId:part1.valueId],
                                       [XTIROperand useWithValueId:part2.valueId] ]];
        }

    XTIROpcode op = binaryOpcodeFor(node.op, operandASTType, &isCmp, &pred);
    if (op == XTIROpUnreachable)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: unhandled binary op"];
        return nil;
        }
    // A `^` is a PAIR, and comparing one compares BOTH words — the receiver and
    // the code. A single-word compare is not a cheaper version of that, it is a
    // different question with a different answer: after a receiver dies the
    // auto-zero clears recv and leaves code, so a one-word compare says "equal
    // to zero" and a two-word compare says "not equal". The back ends disagreed
    // about which they did (arm64 one word, xt6502 two), which is bug 031.
    //
    // Expanded HERE rather than per back end so there is one answer everywhere:
    //   (a.recv == b.recv) && (a.code == b.code)      for ==
    //   (a.recv != b.recv) || (a.code != b.code)      for !=
    //
    // `if (h)` remains the LIVENESS test — it reads the receiver word alone —
    // and the two are deliberately different questions. Use `if (h)` to ask
    // whether an action is still callable; use `==` to ask whether two `^`s
    // name the same thing (bound_method_widen.xc T4).
    if (isCmp && operandASTType && operandASTType.boundMethodSignature != nil && (node.op == XTBinaryOpEq || node.op == XTBinaryOpNeq))
        {
        BOOL wantEq = (node.op == XTBinaryOpEq);
        XTIRType* boolT = [XTIRType boolType];
        XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
        XTIRType* u16T = [XTIRType u16Type];
        XTIRValue* parts[2];
        for (int w = 0; w < 2; w++)
            {
            XTIRValue* lw = [self emitInsnOpcode:XTIROpAggExtract
                                          result:ptrT
                                        operands:@[ [XTIROperand useWithValueId:l.valueId],
                                                    [XTIROperand immIWithType:u16T
                                                                        value:w] ]];
            XTIRValue* rw = [self emitInsnOpcode:XTIROpAggExtract
                                          result:ptrT
                                        operands:@[ [XTIROperand useWithValueId:r.valueId],
                                                    [XTIROperand immIWithType:u16T
                                                                        value:w] ]];
            if (!lw || !rw)
                return nil;
            XTIRValue* c = [self allocateValueOfType:boolT atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                             result:c
                                                           operands:@[ [XTIROperand useWithValueId:lw.valueId],
                                                                       [XTIROperand useWithValueId:rw.valueId] ]
                                                          predicate:(wantEq ? XTIRICmpEQ : XTIRICmpNE)
                                                          dbgLoc:nil]];
            parts[w] = c;
            }
        return [self emitInsnOpcode:(wantEq ? XTIROpAnd : XTIROpOr)
                             result:boolT
                           operands:@[ [XTIROperand useWithValueId:parts[0].valueId],
                                       [XTIROperand useWithValueId:parts[1].valueId] ]];
        }

    XTIRType* resultIRType = isCmp ? [XTIRType boolType]
                                   : [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIRType)
        return nil;
    XTIRValue* rv = [self allocateValueOfType:resultIRType atSite:self.currentBlock];
    NSArray<XTIROperand*>* operands = @[ [XTIROperand useWithValueId:l.valueId],
                                         [XTIROperand useWithValueId:r.valueId] ];
    XTIRInsn* insn;
    if (isCmp)
        {
        insn = [[XTIRInsn alloc] initWithOpcode:op
                                         result:rv
                                       operands:operands
                                      predicate:pred
                                         dbgLoc:nil];
        }
    else
        {
        insn = [[XTIRInsn alloc] initWithOpcode:op
                                         result:rv
                                       operands:operands
                                         dbgLoc:nil];
        }
    [self.currentBlock appendInstruction:insn];
    return rv;
    }

// Lower `p + N` / `N + p` / `p - N` to ElementAddr. The pointer
// operand stays as the base; the integer is the scaled index. For
// subtraction, negate the index first so ElementAddr's "scale +
// add" form still applies.
- (nullable XTIRValue*)lowerPtrArithmetic:(XTBinaryExprNode*)node
    {
    XTType* lt = node.left.resolvedType;
    XTType* rt = node.right.resolvedType;
    BOOL lptr = (lt && lt.kind == XTTypeKindPointer);
    BOOL rptr = (rt && rt.kind == XTTypeKindPointer);

    // `p - q` — pointer DIFFERENCE, in ELEMENTS as C has it. This used to be
    // refused outright ("pointer - pointer not yet supported"), which is why
    // the shape described in the old comment is now simply built: PtrToInt
    // both sides, Sub, then divide by the element size. The divide is skipped
    // for a 1-byte element, where it would be an identity.
    //
    // Sema types the result i32 (see the note there on why it is not a
    // per-target ptrdiff_t), so the whole computation runs at i32 and needs no
    // fitting afterwards. Signed divide, because the difference is signed:
    // `p - q` is as legal as `q - p` and one of them is negative.
    if (lptr && rptr)
        {
        XTIRValue* lv = [self lowerExpression:node.left];
        if (!lv)
            return nil;
        XTIRValue* rv = [self lowerExpression:node.right];
        if (!rv)
            return nil;
        // The ptrdiff type, and it must be the one SEMA chose — pointer-width,
        // not a fixed i32. Hardcoding I32 here truncated the address itself:
        // on arm64 the PtrToInt narrowed a 64-bit pointer to 32 bits BEFORE
        // subtracting, so two pointers straddling a 4GB boundary differed by a
        // wrong amount rather than merely a narrow one. Arithmetic width and
        // result width are the same question and have to come from one source.
        NSUInteger pw = [XTPointerType heapPointerWidth];
        XTIRType* dt = pw >= 8   ? [XTIRType i64Type]
                       : pw >= 4 ? [XTIRType i32Type]
                                 : [XTIRType i16Type];
        XTIRValue* li = [self emitInsnOpcode:XTIROpPtrToInt
                                      result:dt
                                    operands:@[ [XTIROperand useWithValueId:lv.valueId] ]];
        XTIRValue* ri = [self emitInsnOpcode:XTIROpPtrToInt
                                      result:dt
                                    operands:@[ [XTIROperand useWithValueId:rv.valueId] ]];
        if (!li || !ri)
            return nil;
        XTIRValue* diff = [self emitInsnOpcode:XTIROpSub
                                        result:dt
                                      operands:@[ [XTIROperand useWithValueId:li.valueId],
                                                  [XTIROperand useWithValueId:ri.valueId] ]];
        if (!diff)
            return nil;
        XTType* pointee = [lt isKindOfClass:[XTPointerType class]]
                              ? ((XTPointerType*)lt).pointeeType
                              : nil;
        NSUInteger esz = pointee ? pointee.byteWidth : 1;
        if (esz <= 1)
            return diff;
        XTIRValue* k = [self allocateValueOfType:dt atSite:self.currentBlock];
        XTIRInsn* kc = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                 result:k
                                               operands:@[ [XTIROperand immIWithType:dt
                                                                               value:(int64_t)esz] ]
                                                 dbgLoc:nil];
        [self.currentBlock appendInstruction:kc];
        return [self emitInsnOpcode:XTIROpSDiv
                             result:dt
                           operands:@[ [XTIROperand useWithValueId:diff.valueId],
                                       [XTIROperand useWithValueId:k.valueId] ]];
        }

    XTASTNode* ptrSide = lptr ? node.left : node.right;
    XTASTNode* idxSide = lptr ? node.right : node.left;

    XTIRValue* ptrVal = [self lowerExpression:ptrSide];
    if (!ptrVal)
        return nil;
    XTIRValue* idxVal = [self lowerExpression:idxSide];
    if (!idxVal)
        return nil;

    // ElementAddr expects an I16/U16 index. Coerce if narrower.
    XTType* idxAST = idxSide.resolvedType;
    if (idxAST && idxAST.byteWidth < 2)
        {
        idxVal = [self coerceValue:idxVal
                          fromType:idxAST
                            toType:[XTType u16Type]
                          location:node.location];
        idxAST = [XTType u16Type];
        }

    // Subtraction: negate the index before the ElementAddr. The negated index
    // is a SIGNED offset (`p - 2` → -2), so type it signed — the backend then
    // sign-extends it when folding it into the 64-bit address (a U16 type would
    // make it zero-extend -2 to +65534 and walk off into a wild address).
    //
    // The Neg must be typed at the index's OWN width, not a fixed I16. Hard-
    // coding I16 emitted `%n:I16 = Neg %idx:I64` for `p - (i64)n`: the arm64
    // in-house assembler refused the result (`neg w10, x27` — w and x cannot be
    // mixed), and the wasm writer asks the Neg RESULT's type to decide whether
    // to `i32.wrap_i64`, so it skipped the wrap and handed an i64 to i32.sub.
    // The `+` path has no Neg, which is exactly why `p + (i64)n` always worked
    // and only `p - (i64)n` broke (bug 39).
    if (node.op == XTBinaryOpSub)
        {
        NSUInteger iw = idxVal.type ? idxVal.type.byteWidth : 2;
        XTType* negAST = iw >= 8   ? [XTType i64Type]
                         : iw >= 4 ? [XTType i32Type]
                                   : [XTType i16Type];
        XTIRType* idxIR = [self irTypeForASTType:negAST at:node.location]
                              ?: idxVal.type;
        idxVal = [self emitInsnOpcode:XTIROpNeg
                               result:idxIR
                             operands:@[ [XTIROperand useWithValueId:idxVal.valueId] ]];
        if (!idxVal)
            return nil;
        }

    // ElementAddr yields a POINTER of the base's type (base + scaled index) —
    // not `node.resolvedType`, which sema may report as the element type for
    // `p + N` inside a deref. Mistyping it as the element scalar made a
    // byte-addressed backend tolerate it but arm64 picked a 32-bit w-reg for
    // the 8-byte pointer result, emitting an invalid `add w,x,#imm`.
    XTIRType* resultIR = ptrVal.type
                             ?: [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIR)
        return nil;
    [self emitBoundsCheckPtr:ptrVal index:idxVal at:node.location];
    return [self emitInsnOpcode:XTIROpElementAddr
                         result:resultIR
                       operands:@[ [XTIROperand useWithValueId:ptrVal.valueId],
                                   [XTIROperand useWithValueId:idxVal.valueId] ]];
    }

#pragma mark - Unary expressions

- (nullable XTIRValue*)lowerUnaryExpr:(XTUnaryExprNode*)node
    {
    // AddrOf needs to fire BEFORE we lower the operand — `&x`
    // doesn't read x; it returns the pinned slot's address. Reading
    // the operand here would emit a spurious Load.
    if (node.op == XTUnaryOpAddrOf)
        {
        // Plain `&x` — pinned-local OR global. Pinned wins (a local
        // can shadow a global; sema permits this).
        if (node.operand.nodeKind == XTASTNodeKindIdentifier)
            {
            XTIdentifierNode* idn = (XTIdentifierNode*)node.operand;
            XTIRPinnedLocal* pl = self.pinnedLocals[idn.identName];
            if (pl)
                {
                XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!resIR)
                    return nil;
                // A weak / auto-zeroing local (a `weak:` slot or a callback,
                // which auto-zeroes when its receiver dies) sits past two hidden
                // link words, so its ADDRESS is the payload, not the slot base —
                // exactly as reads/writes of it route through pinnedAddr's
                // FieldAddr(base, 2). Taking the bare AddrOf of the slot instead
                // handed `&cb` the link region, so `&cb` word[0] read the null
                // `prev` link rather than the pair's recv (bug 168).
                if ([self astTypeIsWeakSlot:self.pinnedLocalASTType[idn.identName]])
                    {
                    return [self pinnedAddr:pl name:idn.identName outType:NULL];
                    }
                return [self emitInsnOpcode:XTIROpAddrOf
                                     result:resIR
                                   operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                }
            NSNumber* gid = self.globalsByName[idn.identName];
            if (gid)
                {
                XTIRSymbol* sym = [self.module symbolForId:gid.unsignedIntegerValue];
                if (!sym)
                    {
                    [self softFailLoweringAt:node.location
                                 withMessage:[NSString stringWithFormat:
                                                           @"lowering: global '%@' lost its symbol", idn.identName]];
                    return nil;
                    }
                XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!resIR)
                    resIR = [XTIRType ptrToType:sym.globalType window:XTIRWindowUnbanked];
                return [self emitInsnOpcode:XTIROpAddrOf
                                     result:resIR
                                   operands:@[ [XTIROperand symWithSymbolId:gid.unsignedIntegerValue] ]];
                }
            // `&function` — the identifier names a module function, so
            // its address is a function pointer. Emit AddrOf(funcSym):
            // the backend renders it as the function-label address
            // (`#<_fn` / `#>_fn`), exactly the value an indirect call
            // (lowerCallExpr's isIndirectCall path) dispatches through.
            XTIRSymbol* fnSym = [self.module symbolForName:idn.identName];
            if (fnSym && fnSym.kind == XTIRSymbolKindFunction)
                {
                XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!resIR)
                    resIR = [XTIRType ptrToType:[XTIRType voidType]
                                         window:XTIRWindowUnbanked];
                XTIRSymbolId fid = [self.module.symbols indexOfObjectIdenticalTo:fnSym];
                return [self emitInsnOpcode:XTIROpAddrOf
                                     result:resIR
                                   operands:@[ [XTIROperand symWithSymbolId:fid] ]];
                }
            // `&field` inside a method — an IVAR, reached through the implicit self.
            // Not a pinned local, not a global, not a function, so it used to fall out
            // of the bottom of this chain and ABANDON the function: a note, a build
            // that succeeded, and no code at all. `&caret` handed a garbage pointer to
            // whoever wanted it.
            if (self.currentClassInfo && self.currentSelf)
                {
                NSNumber* slot = nil;
                XTType* ivarAST = nil;
                for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
                    {
                    slot = ci.ivarFieldIndex[idn.identName];
                    if (slot)
                        {
                        ivarAST = ci.ivarASTType[idn.identName];
                        break;
                        }
                    }
                if (slot && ivarAST)
                    {
                    XTIRType* fieldIR = [self irTypeForASTType:ivarAST at:node.location];
                    if (!fieldIR)
                        return nil;
                    XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
                    if (!resIR)
                        resIR = [XTIRType ptrToType:fieldIR window:XTIRWindowUnbanked];
                    return [self emitFieldAddr:self.currentSelf
                                    fieldIndex:slot.unsignedIntegerValue
                                    resultType:resIR];
                    }
                }
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: & on '%@' not pinned (pre-scan miss or parameter)",
                                                   idn.identName]];
            return nil;
            }
        // `&obj.method` — a bound method. Build the {recv, code} fat pointer.
        // Sema stamped resolvedBoundMethod (and the vtable slot, if the
        // method has one). See private:docs/Design/bound-methods.md.
        if (node.operand.nodeKind == XTASTNodeKindMemberAccess && ((XTMemberAccessNode*)node.operand).resolvedBoundMethod != nil)
            {
            return [self lowerBoundMethodRef:(XTMemberAccessNode*)node.operand
                                      ofExpr:node];
            }
        // `&obj.field` / `&p->field` — compute base address (recursing
        // for nested struct paths), then FieldAddr against the field
        // index. NO Load — the result IS the address.
        if (node.operand.nodeKind == XTASTNodeKindMemberAccess)
            {
            XTMemberAccessNode* m = (XTMemberAccessNode*)node.operand;
            XTType* baseT = m.base.resolvedType;
            XTType* pointee = baseT;
            if (baseT && [baseT isKindOfClass:[XTPointerType class]])
                {
                pointee = ((XTPointerType*)baseT).pointeeType;
                }
            // A CLASS base — `&self.ted`, `&obj.field`. Only structs were handled, so
            // taking the address of a class FIELD abandoned the whole function: a note,
            // a successful build, and no code. `o.ob_spec = (pointer)&ted` then carried
            // garbage.
            if (pointee && pointee.kind == XTTypeKindClass)
                {
                XTIRClassInfo* baseCi = self.classesByName[pointee.displayName];
                NSNumber* slot = nil;
                XTType* ivarAST = nil;
                for (XTIRClassInfo* ci = baseCi; ci != nil; ci = ci.parent)
                    {
                    slot = ci.ivarFieldIndex[m.memberName];
                    if (slot)
                        {
                        ivarAST = ci.ivarASTType[m.memberName];
                        break;
                        }
                    }
                if (!slot || !ivarAST)
                    {
                    [self softFailLoweringAt:node.location
                                 withMessage:[NSString stringWithFormat:
                                                           @"lowering: class '%@' has no ivar '%@'",
                                                           pointee.displayName, m.memberName]];
                    return nil;
                    }
                XTIRValue* basePtr = [self selfPointerForClassBase:m.base];
                if (!basePtr)
                    return nil;
                XTIRType* fieldIR = [self irTypeForASTType:ivarAST at:node.location];
                if (!fieldIR)
                    return nil;
                XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!resIR)
                    resIR = [XTIRType ptrToType:fieldIR window:XTIRWindowUnbanked];
                return [self emitFieldAddr:basePtr
                                fieldIndex:slot.unsignedIntegerValue
                                resultType:resIR];
                }
            if (!pointee || pointee.kind != XTTypeKindStruct || ![pointee isKindOfClass:[XTStructType class]])
                {
                [self softFailLoweringAt:node.location
                             withMessage:@"lowering: & on member-access requires a struct-typed base"];
                return nil;
                }
            XTStructType* st = (XTStructType*)pointee;
            NSUInteger fieldIndex = 0;
            XTType* fieldAST = nil;
            if (![self structType:st
                       fieldNamed:m.memberName
                            index:&fieldIndex
                          astType:&fieldAST])
                {
                [self softFailLoweringAt:node.location
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: struct '%@' has no field '%@'",
                                                       pointee.displayName, m.memberName]];
                return nil;
                }
            XTIRValue* baseAddr = nil;
            if (m.isArrow)
                {
                baseAddr = [self lowerExpression:m.base];
                }
            else
                {
                baseAddr = [self addressOfStructLValue:m.base];
                }
            if (!baseAddr)
                return nil;
            XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:node.location];
            if (!fieldIRType)
                return nil;
            XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
            if (!resIR)
                resIR = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
            return [self emitFieldAddr:baseAddr
                            fieldIndex:fieldIndex
                            resultType:resIR];
            }
        // `&arr[i]` — delegate to emitSubscriptAddress which handles
        // both array-decay and pointer bases for the subscript form.
        if (node.operand.nodeKind == XTASTNodeKindSubscriptExpr)
            {
            XTSubscriptExprNode* sub = (XTSubscriptExprNode*)node.operand;
            XTIRType* resIR = [self irTypeForASTType:node.resolvedType at:node.location];
            if (!resIR)
                return nil;
            return [self emitSubscriptAddress:sub.base
                                        index:sub.index
                                     location:sub.location];
            }
        // `&*e` — address-of-dereference cancels: the address IS the very
        // pointer `e` was about to dereference. The cast form `&(*(T*)p)`
        // (bug 18) otherwise fell through to the catch-all below with no
        // location. Fold to `e`; its value already has the &-expression's
        // pointer type.
        if (node.operand.nodeKind == XTASTNodeKindUnaryExpr && ((XTUnaryExprNode*)node.operand).op == XTUnaryOpDeref)
            {
            return [self lowerExpression:((XTUnaryExprNode*)node.operand).operand];
            }
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: & supported only on identifiers or struct member-access"];
        return nil;
        }

    // Prefix `++x` / `--x` need the LVALUE (the name to rebind or the
    // subscript slot to store back), not the rvalue lowerExpression
    // would produce — so, like AddrOf, handle them before the operand
    // is read below. Prefix returns the NEW value (postfix the old);
    // both share lowerIncDecOn:.
    if (node.op == XTUnaryOpPreInc || node.op == XTUnaryOpPreDec)
        {
        return [self lowerIncDecOn:node.operand
                             isInc:(node.op == XTUnaryOpPreInc)
                         returnNew:YES
                          location:node.location];
        }

    XTIRValue* operand = [self lowerExpression:node.operand];
    if (!operand)
        return nil;
    XTIRType* resultIRType = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIRType)
        return nil;
    switch (node.op)
        {
    case XTUnaryOpNeg:
        // Float / double negation must use FNeg (flip the sign), not
        // the integer Neg — a two's-complement of the raw float bit
        // pattern turns e.g. the literal -0.55 into garbage (~-7.6).
        // Both backends lower FNeg (arm64 `fneg`, xt6502 sign-bit flip).
        if (XTIRTypeKindIsFloating(resultIRType.kind))
            {
            return [self emitInsnOpcode:XTIROpFNeg
                                 result:resultIRType
                               operands:@[ [XTIROperand useWithValueId:operand.valueId] ]];
            }
        return [self emitInsnOpcode:XTIROpNeg
                             result:resultIRType
                           operands:@[ [XTIROperand useWithValueId:operand.valueId] ]];
    case XTUnaryOpBitNot:
        return [self emitInsnOpcode:XTIROpNot
                             result:resultIRType
                           operands:@[ [XTIROperand useWithValueId:operand.valueId] ]];
    case XTUnaryOpDeref:
        {
        // `@p` is a pointer dereference. If the operand is
        // integer-typed (e.g. `@$D01A` where the operand was
        // a u16 literal), insert an IntToPtr so Load sees a
        // proper pointer. The pointee type is the unary's
        // resolved type (sema sets it to what the pointer
        // points at).
        XTIRType* opType = operand.type;
        XTIRType* pointeeIR = resultIRType;
        if (opType && opType.kind != XTIRTypeKindPtr)
            {
            XTIRType* ptrType = [XTIRType ptrToType:resultIRType
                                             window:XTIRWindowUnbanked];
            operand = [self emitInsnOpcode:XTIROpIntToPtr
                                    result:ptrType
                                  operands:@[ [XTIROperand useWithValueId:operand.valueId] ]];
            if (!operand)
                return nil;
            }
        else if (opType && opType.pointeeType && resultIRType && opType.pointeeType.byteWidth != resultIRType.byteWidth)
            {
            // resultIRType comes from the deref's AST resolvedType, which is
            // arch-dependent and wrong for `@(p ± N)` (byte vs the real u16).
            // The IR pointer's pointee is reliable — load at its width.
            pointeeIR = opType.pointeeType;
            }
        return [self emitLoad:operand pointeeType:pointeeIR];
        }
    case XTUnaryOpLogNot:
        {
        // `!x` → (x == 0) as a bool, mirroring the binary `==`
        // path (ICmp + XTIRICmpEQ). Integer/bool operands compare
        // directly against a same-typed Const #0; a pointer is
        // PtrToInt'd to u16 first (ICmp wants integer operands).
        // A float operand isn't handled yet.
        XTIRValue* cmpOperand = operand;
        XTIRType* cmpType = operand.type;

        // A bound method (`^`) is a two-field aggregate, so it is neither a
        // pointer nor an integer and would fall straight into the soft-fail
        // below — even though `if (h)` on the very same value works. Test it
        // the way lowerConditionExpr does: extract the RECV word (field 0)
        // and compare that against zero. `!h` is then exactly `!respondsTo`,
        // which is how an optional protocol method gets tested.
        XTType* opAST = node.operand.resolvedType;
        // Same rule as lowerConditionExpr: `!(f == 0)` has a `^` AST type
        // but has already lowered to a Bool, and extracting a field from
        // that is meaningless.
        if (opAST && opAST.boundMethodSignature != nil && operand.type && operand.type.kind == XTIRTypeKindAgg)
            {
            cmpType = [XTIRType ptrToType:[XTIRType voidType]
                                   window:XTIRWindowUnbanked];
            cmpOperand = [self emitInsnOpcode:XTIROpAggExtract
                                       result:cmpType
                                     operands:@[ [XTIROperand useWithValueId:operand.valueId],
                                                 [XTIROperand immIWithType:[XTIRType u16Type]
                                                                     value:0] ]];
            if (!cmpOperand)
                return nil;
            }

        if (cmpType && cmpType.kind == XTIRTypeKindPtr)
            {
            // PtrToInt the value we actually intend to test — which for a
            // `^` is the extracted recv word above, NOT the aggregate it
            // came out of. Narrowing the whole 16-byte aggregate to a u16
            // yields garbage, and `!h` then answers at random.
            XTIRValue* src = cmpOperand;
            cmpType = [XTIRType u16Type];
            cmpOperand = [self emitInsnOpcode:XTIROpPtrToInt
                                       result:cmpType
                                     operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
            if (!cmpOperand)
                return nil;
            }
        // A float operand: `!f` is `f == 0.0` (bug 181). Compare against a
        // zero-bits constant (0.0 is all-zero IEEE bytes) with FCmp OEQ,
        // exactly as the binary `f == 0` path does, yielding the bool.
        if (cmpType && XTIRTypeKindIsFloating(cmpType.kind))
            {
            XTIRValue* fzero = [self allocateValueOfType:cmpType atSite:self.currentBlock];
            XTIRInsn* fcz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                      result:fzero
                                                    operands:@[ [XTIROperand immFWithType:cmpType rawBytes:0] ]
                                                      dbgLoc:nil];
            [self.currentBlock appendInstruction:fcz];
            XTIRValue* fr = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
            XTIRInsn* fcmp = [[XTIRInsn alloc] initWithOpcode:XTIROpFCmp
                                                       result:fr
                                                     operands:@[ [XTIROperand useWithValueId:cmpOperand.valueId],
                                                                 [XTIROperand useWithValueId:fzero.valueId] ]
                                                    predicate:XTIRFCmpOEQ
                                                       dbgLoc:nil];
            [self.currentBlock appendInstruction:fcmp];
            return fr;
            }
        if (!cmpType || !(XTIRTypeKindIsInteger(cmpType.kind) || cmpType.kind == XTIRTypeKindBool))
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: ! on non-integer operand not yet supported"];
            return nil;
            }
        XTIRValue* zero = [self allocateValueOfType:cmpType atSite:self.currentBlock];
        XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                 result:zero
                                               operands:@[ [XTIROperand immIWithType:cmpType value:0] ]
                                                 dbgLoc:nil];
        [self.currentBlock appendInstruction:cz];
        XTIRValue* rv = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
        XTIRInsn* cmp = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                  result:rv
                                                operands:@[ [XTIROperand useWithValueId:cmpOperand.valueId],
                                                            [XTIROperand useWithValueId:zero.valueId] ]
                                               predicate:XTIRICmpEQ
                                                  dbgLoc:nil];
        [self.currentBlock appendInstruction:cmp];
        return rv;
        }
    default:
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: unsupported unary op"];
        return nil;
        }
    }

#pragma mark - Postfix ++/--

- (nullable XTIRValue*)lowerPostfixExpr:(XTPostfixExprNode*)node
    {
    return [self lowerIncDecOn:node.operand
                         isInc:(node.postfixOp == XTPostfixOpInc)
                     returnNew:NO
                      location:node.location];
    }

// Shared core for `++`/`--` in both postfix (`x++`) and prefix (`++x`)
// position. Loads the lvalue's current value, adds/subtracts 1, stores
// it back, and returns the NEW value (prefix) or the OLD value
// (postfix). Covers the subscript (`arr[i]`) and identifier operand
// shapes; other lvalues soft-fail (matching the historical postfix
// coverage — member-access / deref operands are not handled here).
// The address of a member lvalue (`s.n`, `p->m`, `self.ivar`) as a
// Ptr(field), plus the field's IR type in *outElem. Mirrors the `&obj.field`
// address computation (class ivar via selfPointerForClassBase, struct field
// via addressOfStructLValue / the base pointer) so a member ++/-- and the
// address-of path agree on where the field lives. Reports the specific reason
// and returns nil on a non-struct/non-class base or a missing field.
- (nullable XTIRValue*)memberFieldAddr:(XTMemberAccessNode*)m
                            pointeeOut:(XTIRType* _Nullable* _Nullable)outElem
                              location:(nullable XTSourceLocation*)loc
    {
    XTType* baseT = m.base.resolvedType;
    XTType* pointee = baseT;
    if (baseT && [baseT isKindOfClass:[XTPointerType class]])
        {
        pointee = ((XTPointerType*)baseT).pointeeType;
        }
    // Class base — `self.count`, `obj.field`: the reference is the address and
    // the ivar's slot comes from the class map (walking the parent chain).
    if (pointee && pointee.kind == XTTypeKindClass)
        {
        XTIRClassInfo* baseCi = self.classesByName[pointee.displayName];
        NSNumber* slot = nil;
        XTType* ivarAST = nil;
        for (XTIRClassInfo* ci = baseCi; ci != nil; ci = ci.parent)
            {
            slot = ci.ivarFieldIndex[m.memberName];
            if (slot)
                {
                ivarAST = ci.ivarASTType[m.memberName];
                break;
                }
            }
        if (!slot || !ivarAST)
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: class '%@' has no ivar '%@'", pointee.displayName, m.memberName]];
            return nil;
            }
        XTIRValue* basePtr = [self selfPointerForClassBase:m.base];
        if (!basePtr)
            return nil;
        XTIRType* fieldIR = [self irTypeForASTType:ivarAST at:loc];
        if (!fieldIR)
            return nil;
        if (outElem)
            *outElem = fieldIR;
        return [self emitFieldAddr:basePtr
                        fieldIndex:slot.unsignedIntegerValue
                        resultType:[XTIRType ptrToType:fieldIR window:XTIRWindowUnbanked]];
        }
    if (!pointee || pointee.kind != XTTypeKindStruct || ![pointee isKindOfClass:[XTStructType class]])
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: member ++/-- requires a struct- or class-typed base"];
        return nil;
        }
    XTStructType* st = (XTStructType*)pointee;
    NSUInteger fieldIndex = 0;
    XTType* fieldAST = nil;
    if (![self structType:st fieldNamed:m.memberName index:&fieldIndex astType:&fieldAST])
        {
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: struct '%@' has no field '%@'", pointee.displayName, m.memberName]];
        return nil;
        }
    // Arrow form (`p->m`) OR a base already a pointer to the struct: the base
    // value IS the address; otherwise it is an lvalue whose address we take.
    BOOL baseIsPointer = (baseT && [baseT isKindOfClass:[XTPointerType class]]);
    XTIRValue* baseAddr = (m.isArrow || baseIsPointer)
                              ? [self lowerExpression:m.base]
                              : [self addressOfStructLValue:m.base];
    if (!baseAddr)
        return nil;
    XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:loc];
    if (!fieldIRType)
        return nil;
    if (outElem)
        *outElem = fieldIRType;
    return [self emitFieldAddr:baseAddr
                    fieldIndex:fieldIndex
                    resultType:[XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked]];
    }

- (nullable XTIRValue*)lowerIncDecOn:(XTASTNode*)operand
                               isInc:(BOOL)isInc
                           returnNew:(BOOL)returnNew
                            location:(nullable XTSourceLocation*)loc
    {
    // Subscript operand: compute the slot address once, Load old,
    // Add/Sub 1, Store new.
    if (operand.nodeKind == XTASTNodeKindSubscriptExpr)
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)operand;
        XTIRValue* addr = [self emitSubscriptAddress:sub.base
                                               index:sub.index
                                            location:loc];
        if (!addr)
            return nil;
        XTIRType* elemIR = [self irTypeForASTType:operand.resolvedType at:loc];
        if (!elemIR)
            return nil;
        XTIRValue* oldVal = [self emitLoad:addr pointeeType:elemIR];
        if (!oldVal)
            return nil;
        if (!XTIRTypeKindIsInteger(elemIR.kind))
            {
            [self softFailLoweringAt:loc
                         withMessage:@"lowering: subscript ++/-- on non-integer element"];
            return nil;
            }
        XTIRValue* one = [self allocateValueOfType:elemIR atSite:self.currentBlock];
        XTIRInsn* cone = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                   result:one
                                                 operands:@[ [XTIROperand immIWithType:elemIR value:1] ]
                                                   dbgLoc:nil];
        [self.currentBlock appendInstruction:cone];
        XTIROpcode op = isInc ? XTIROpAdd : XTIROpSub;
        XTIRValue* newVal = [self emitInsnOpcode:op
                                          result:elemIR
                                        operands:@[ [XTIROperand useWithValueId:oldVal.valueId],
                                                    [XTIROperand useWithValueId:one.valueId] ]];
        if (!newVal)
            return nil;
        [self emitStore:addr value:newVal];
        return returnNew ? newVal : oldVal;
        }
    // Member operand (`s.n++`, `p->m++`): compute the field's address once,
    // then Load old / Add-or-Sub 1 / Store new — mirroring the subscript case.
    // The 0.5 ++/-- rework dropped this lvalue shape while gaining pointer step
    // (c2xc bug 35); `gS.n += 1` kept working only because compound-assign
    // rewrites to `lhs = lhs op rhs` and reuses the member-assign path.
    if (operand.nodeKind == XTASTNodeKindMemberAccess)
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)operand;
        XTIRType* elemIR = nil;
        XTIRValue* fa = [self memberFieldAddr:m pointeeOut:&elemIR location:loc];
        if (!fa || !elemIR)
            return nil; // memberFieldAddr reported the reason
        if (!XTIRTypeKindIsInteger(elemIR.kind))
            {
            [self softFailLoweringAt:loc
                         withMessage:@"lowering: member ++/-- on non-integer field"];
            return nil;
            }
        XTIRValue* oldVal = [self emitLoad:fa pointeeType:elemIR];
        if (!oldVal)
            return nil;
        XTIRValue* one = [self allocateValueOfType:elemIR atSite:self.currentBlock];
        XTIRInsn* cone = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                   result:one
                                                 operands:@[ [XTIROperand immIWithType:elemIR value:1] ]
                                                   dbgLoc:nil];
        [self.currentBlock appendInstruction:cone];
        XTIROpcode op = isInc ? XTIROpAdd : XTIROpSub;
        XTIRValue* newVal = [self emitInsnOpcode:op
                                          result:elemIR
                                        operands:@[ [XTIROperand useWithValueId:oldVal.valueId],
                                                    [XTIROperand useWithValueId:one.valueId] ]];
        if (!newVal)
            return nil;
        [self emitStore:fa value:newVal];
        return returnNew ? newVal : oldVal;
        }
    // Identifier operand — the simple in-locals case.
    if (operand.nodeKind != XTASTNodeKindIdentifier)
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: ++/-- on non-identifier / non-subscript operand"];
        return nil;
        }
    XTIdentifierNode* id = (XTIdentifierNode*)operand;
    // A bare IVAR (`outstanding++` inside a method — implicit self) is a
    // read-modify-write of the ivar SLOT, exactly like `self.outstanding++`.
    // It is NOT the name it shadows: only when the identifier is not a pinned
    // local, plain local, or module global does it resolve to an ivar. Without
    // this the read came from self+FieldAddr+Load but the write rebound a dead
    // SSA local, so the increment was LOST and the next read saw the stale ivar
    // — the reference silently miscompiled it and the port rejected it as a
    // "step of a non-local" (c2xc bug 35, the implicit-this half).
    if (!self.pinnedLocals[id.identName] && !self.locals[id.identName] && !self.globalsByName[id.identName] && self.currentClassInfo && self.currentSelf)
        {
        NSNumber* slot = nil;
        XTType* ivarAST = nil;
        for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
            {
            slot = ci.ivarFieldIndex[id.identName];
            if (slot)
                {
                ivarAST = ci.ivarASTType[id.identName];
                break;
                }
            }
        if (slot && ivarAST)
            {
            XTIRType* fieldIR = [self irTypeForASTType:ivarAST at:loc];
            if (!fieldIR)
                return nil;
            XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                                     fieldIndex:slot.unsignedIntegerValue
                                     resultType:[XTIRType ptrToType:fieldIR window:XTIRWindowUnbanked]];
            if (!XTIRTypeKindIsInteger(fieldIR.kind))
                {
                [self softFailLoweringAt:loc
                             withMessage:@"lowering: member ++/-- on non-integer field"];
                return nil;
                }
            XTIRValue* ivOld = [self emitLoad:fa pointeeType:fieldIR];
            if (!ivOld)
                return nil;
            XTIRValue* ivOne = [self allocateValueOfType:fieldIR atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc]
                                                     initWithOpcode:XTIROpConst
                                                             result:ivOne
                                                           operands:@[ [XTIROperand immIWithType:fieldIR value:1] ]
                                                             dbgLoc:nil]];
            XTIRValue* ivNew = [self emitInsnOpcode:(isInc ? XTIROpAdd : XTIROpSub)
                                             result:fieldIR
                                           operands:@[ [XTIROperand useWithValueId:ivOld.valueId],
                                                       [XTIROperand useWithValueId:ivOne.valueId] ]];
            if (!ivNew)
                return nil;
            [self emitStore:fa value:ivNew];
            return returnNew ? ivNew : ivOld;
            }
        }
    XTIRValue* oldVal = [self lowerIdentifier:id];
    if (!oldVal)
        return nil;
    XTIRType* ty = oldVal.type;
    if (!ty || !XTIRTypeKindIsInteger(ty.kind))
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: ++/-- on non-integer type"];
        return nil;
        }
    // Build a const-1 of the same type, then Add/Sub.
    XTIRValue* one = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIRInsn* cone = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:one
                                             operands:@[ [XTIROperand immIWithType:ty value:1] ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:cone];
    XTIROpcode op = isInc ? XTIROpAdd : XTIROpSub;
    XTIRValue* newVal = [self emitInsnOpcode:op
                                      result:ty
                                    operands:@[ [XTIROperand useWithValueId:oldVal.valueId],
                                                [XTIROperand useWithValueId:one.valueId] ]];
    if (!newVal)
        return nil;
    // Write the new value back. A pinned local (address-taken / asm-named)
    // lives in a frame slot, not the SSA `locals` map — lowerIdentifier
    // reads it via AddrOf+Load, so the increment is lost unless we Store it
    // to the slot (mirrors the subscript case above). A plain SSA local
    // just rebinds in the locals map.
    XTIRPinnedLocal* pl = self.pinnedLocals[id.identName];
    if (pl)
        {
        // Weak local: payload sits past the hidden link words. See pinnedAddr:.
        XTIRType* ptrTy = nil;
        XTIRValue* addr = [self pinnedAddr:pl name:id.identName outType:&ptrTy];
        if (!addr)
            return nil;
        [self emitStore:addr value:newVal];
        }
    else if (self.globalsByName[id.identName] && !self.locals[id.identName])
        {
        // A module global (incl. a static-local's backing global): the
        // read came from AddrOf+Load, so the increment must Store back to
        // memory — without this `g++` / a static-local `a++` wrote a dead
        // SSA value and the next read (or next call) saw the stale value.
        NSNumber* g = self.globalsByName[id.identName];
        XTIRSymbol* gsym = [self.module symbolForId:g.unsignedIntegerValue];
        if (gsym)
            {
            XTIRValue* gAddr = [self globalPayloadAddr:gsym
                                              symbolId:g.unsignedIntegerValue
                                               outType:NULL];
            if (gAddr)
                [self emitStore:gAddr value:newVal];
            }
        }
    else
        {
        self.locals[id.identName] = newVal;
        }
    return returnNew ? newVal : oldVal;
    }

#pragma mark - Assignment

// Map a compound-assignment operator (`+=`, `<<=`, `<:=`, …) to the
// plain binary operator it expands to. Returns NO for XTAssignOpAssign
// (not a compound op) or any operator without a binary equivalent.
- (BOOL)binaryOpForCompoundAssign:(XTAssignOp)aop out:(XTBinaryOp*)out
    {
    switch (aop)
        {
    case XTAssignOpAdd:
        *out = XTBinaryOpAdd;
        return YES;
    case XTAssignOpSub:
        *out = XTBinaryOpSub;
        return YES;
    case XTAssignOpMul:
        *out = XTBinaryOpMul;
        return YES;
    case XTAssignOpDiv:
        *out = XTBinaryOpDiv;
        return YES;
    case XTAssignOpMod:
        *out = XTBinaryOpMod;
        return YES;
    case XTAssignOpBitAnd:
        *out = XTBinaryOpBitAnd;
        return YES;
    case XTAssignOpBitOr:
        *out = XTBinaryOpBitOr;
        return YES;
    case XTAssignOpBitXor:
        *out = XTBinaryOpBitXor;
        return YES;
    case XTAssignOpShl:
        *out = XTBinaryOpShl;
        return YES;
    case XTAssignOpShr:
        *out = XTBinaryOpShr;
        return YES;
    case XTAssignOpRol:
        *out = XTBinaryOpRol;
        return YES;
    case XTAssignOpRor:
        *out = XTBinaryOpRor;
        return YES;
    default:
        return NO;
        }
    }

- (nullable XTIRValue*)lowerAssignExpr:(XTAssignExprNode*)node
    {
    if (node.assignOp != XTAssignOpAssign)
        {
        // Compound assignment (`lhs op= rhs`): rewrite to the plain form
        // `lhs = lhs op rhs` and recurse, reusing every lvalue shape the
        // plain path already handles (identifier / pinned / global / ivar
        // / member-access / subscript / deref). The lhs node is shared
        // between the value-read (inside the binary) and the store target;
        // for the lvalue shapes that appear in practice (a bare name, a
        // member, or a subscript with a side-effect-free index) this reads
        // the address-forming subexpressions twice with no observable
        // double-evaluation. The arithmetic is performed at the lhs type
        // and the result coerced back on store — i.e. `lhs = (Tlhs)(lhs op rhs)`.
        XTBinaryOp bop;
        if (![self binaryOpForCompoundAssign:node.assignOp out:&bop])
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: unsupported compound-assignment operator"];
            return nil;
            }
        XTBinaryExprNode* bin = [[XTBinaryExprNode alloc] initWithOp:bop
                                                                left:node.lhs
                                                               right:node.rhs
                                                            location:node.location];
        bin.resolvedType = node.lhs.resolvedType ?: node.resolvedType;
        XTAssignExprNode* plain = [[XTAssignExprNode alloc] initWithOp:XTAssignOpAssign
                                                                   lhs:node.lhs
                                                                   rhs:bin
                                                              location:node.location];
        plain.resolvedType = node.resolvedType ?: node.lhs.resolvedType;
        return [self lowerAssignExpr:plain];
        }

    // Property-setter rewrite: `obj.prop = expr` where sema resolved a
    // one-arg `set<Prop>` method routes through a method call instead of
    // an ivar store. Lower the RHS once (it is both the setter arg and the
    // assignment's value), coerce to the setter's param type, call the
    // setter, and yield the assigned value. Compound assignment desugars to
    // `obj.prop = obj.prop OP rhs`, so the getter rewrite above runs on the
    // read side and this setter runs on the write side, once each.
    if (node.lhs.nodeKind == XTASTNodeKindMemberAccess && [node.resolvedSetterMethod isKindOfClass:[XTMethodDeclNode class]] && node.resolvedSetterClass)
        {
        XTMethodDeclNode* setter = (XTMethodDeclNode*)node.resolvedSetterMethod;
        XTMemberAccessNode* lhsM = (XTMemberAccessNode*)node.lhs;
        XTIRValue* selfVal = [self lowerExpression:lhsM.base];
        if (!selfVal)
            return nil;
        XTIRValue* rhsVal = [self lowerExpression:node.rhs];
        if (!rhsVal)
            return nil;
        XTType* paramAST = (setter.parameters.count > 0)
                               ? setter.parameters[0].paramType
                               : nil;
        if (paramAST)
            {
            rhsVal = [self coerceValue:rhsVal
                              fromType:node.rhs.resolvedType
                                toType:paramAST
                              location:node.location];
            }
        (void)[self emitAccessorCallTo:setter
                             className:node.resolvedSetterClass
                                  self:selfVal
                                  args:@[ rhsVal ]
                            resultType:nil
                              location:node.location];
        return rhsVal;
        }

    // Member-access LHS: `obj.field = expr` (or `self.field = expr`
    // inside a method body). Walk through to FieldAddr+Store; for
    // class-pointer fields apply ARC release-old / retain-new.
    if (node.lhs.nodeKind == XTASTNodeKindMemberAccess)
        {
        return [self lowerMemberAssign:(XTMemberAccessNode*)node.lhs
                                   rhs:node.rhs
                              location:node.location];
        }
    // Subscript LHS: `arr[i] = expr`. Compute the slot address
    // via ElementAddr, lower the RHS, coerce, emit Store. Same
    // shape as deref-LHS below, just with the address coming
    // from an ElementAddr rather than a bare ptr value.
    if (node.lhs.nodeKind == XTASTNodeKindSubscriptExpr)
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)node.lhs;
        // The SUBSCRIPT's position, not the assignment's. A failed bounds
        // check on `a[k] = v` reported the column of the `=`, which is not
        // where the bad index is.
        XTIRValue* addr = [self emitSubscriptAddress:sub.base
                                               index:sub.index
                                            location:sub.location ?: node.location];
        if (!addr)
            return nil;
        // Struct-array element whole-struct assign (`sharr[i] = makeHolder(...)`):
        // the element is a struct embedding owned class pointers. For an OWNED rhs
        // (sret maker/return) release+zero the OLD element's strong fields BEFORE
        // the RHS (which may RVO into the element), then the +1 fields are adopted
        // via the store. (Borrowed struct-element assign is rare → plain store.)
        XTArrayType* saAt = (sub.base.nodeKind == XTASTNodeKindIdentifier)
                                ? self.strongStructArrayLocals[((XTIdentifierNode*)sub.base).identName]
                                : nil;
        XTStructType* saElemSt =
            (saAt && [saAt.elementType isKindOfClass:[XTStructType class]])
                ? (XTStructType*)saAt.elementType
                : nil;
        BOOL saOwned = saElemSt && !([self arcRhsIsBorrowed:node.rhs] && (node.rhs.nodeKind == XTASTNodeKindIdentifier || node.rhs.nodeKind == XTASTNodeKindMemberAccess || node.rhs.nodeKind == XTASTNodeKindSubscriptExpr));
        if (saOwned)
            {
            [self emitStructARCWalkAt:addr type:saElemSt mode:XTStructARCRelease];
            [self emitStructARCWalkAt:addr type:saElemSt mode:XTStructARCZeroInit];
            }
        XTType* elemAST = node.lhs.resolvedType;
        // ARC: reassigning an element of a strong local array of class
        // pointers (`arr[i] = expr`) releases the old occupant and retains
        // a borrowed RHS — mirroring a scalar strong slot. Gated on the
        // base being a tracked strong array local so heap / borrowed
        // arrays keep the plain store. The slot's final value is freed by
        // the scope-exit array walker.
        BOOL strongElem = NO;
        XTIRType* elemIR = nil;
        XTIRValue* oldVal = nil;
        BOOL strongBase = NO;
        if (sub.base.nodeKind == XTASTNodeKindIdentifier)
            {
            NSString* bn = ((XTIdentifierNode*)sub.base).identName;
            if (self.strongArrayLocals[bn])
                {
                strongBase = YES;
                }
            else if (self.globalsByName[bn] && !self.locals[bn] && [sub.base.resolvedType isKindOfClass:[XTArrayType class]] && elemAST && [self astTypeIsClassPointer:elemAST])
                {
                // A GLOBAL array of class pointers — `String* g[N];` in BSS.
                //
                // This case used to fall through to the plain store, because the
                // test above asks whether the base is a tracked strong array
                // LOCAL and a global is not one. The elements are therefore raw
                // pointer slots: `g[i] = s` stored the pointer without retaining,
                // s was freed at scope exit, and the slot dangled — a stray
                // object read back out of reused memory, or a segfault. The
                // scalar global path never had this hole because it gates on the
                // TYPE (astTypeIsClassPointer) rather than on locals membership.
                //
                // Only a real fixed-size array qualifies (XTArrayType). A global
                // POINTER — a heap `new T[N]` or a borrowed T** — keeps the plain
                // store, exactly as the local gate intends: those elements are
                // owned elsewhere. Unlike a local, nothing releases these slots at
                // scope exit, which matches how a strong scalar global behaves.
                strongBase = YES;
                }
            }
        if (strongBase)
            {
            strongElem = YES;
            elemIR = [self irTypeForASTType:elemAST at:node.location];
            if (elemIR)
                oldVal = [self emitLoad:addr pointeeType:elemIR];
            }
        XTIRValue* rhsVal = [self lowerExpression:node.rhs];
        if (!rhsVal)
            return nil;
        if (elemAST)
            {
            rhsVal = [self coerceValue:rhsVal
                              fromType:node.rhs.resolvedType
                                toType:elemAST
                              location:node.location];
            }
        if (strongElem)
            {
            if ([self arcRhsIsBorrowed:node.rhs])
                {
                if ([self astTypeIsAnyClassPointer:node.rhs.resolvedType])
                    [self emitRetain:rhsVal];
                }
            else
                {
                [self consumeOwnedTemp:rhsVal]; // slot adopts the +1 temp
                }
            }
        [self emitStore:addr value:rhsVal];
        if (strongElem && oldVal)
            [self emitRelease:oldVal];
        // Weak array element (`weak:T@ arr[i]`): register the slot in the
        // side-table so the pointee's dealloc auto-zeroes it (mirrors the
        // weak-ivar/global assign). Element assigns previously emitted NO
        // registration at all — weak_array relied on it but never got it. A
        // re-point unregisters the prior entry first; scope exit unregisters
        // every slot (emitWeakArrayUnregisterForLocalNamed).
        if ([self astTypeIsWeakClassPointer:elemAST])
            {
            [self emitWeakUnregisterSlot:addr];
            [self emitWeakRegisterSlot:addr obj:rhsVal];
            // A weak slot does NOT own its referent: a +1 RHS (`new T`, a
            // returnsRetained call) was adopted by the store but nothing
            // balanced it, so the +1 leaked (bug 170, the element sibling of
            // 153). Release it after the register — if this was the last strong
            // reference the auto-zero nils the slot. A borrowed RHS owns
            // nothing and must not be released.
            if (![self arcRhsIsBorrowed:node.rhs])
                [self emitRelease:rhsVal];
            }
        // A bound method (`^`) element is a weak slot too — and the gate above
        // is on astTypeIsWeakClassPointer, which a `^` is NOT. Without this the
        // element's storage had its link words but nothing ever LINKED it, so a
        // `^` in an array stayed live after its receiver died: `if (arr[i])`
        // tested true and called through freed memory. Gap F, in an array.
        if (elemAST.boundMethodSignature != nil)
            {
            [self emitWeakBoundRegisterAt:addr
                                    value:rhsVal
                                boundType:elemAST
                                  rhsNode:node.rhs];
            }
        return rhsVal;
        }

    // Deref LHS: `@p = expr`. Lower the pointer, lower the RHS,
    // emit Store. The pointee type comes from the unary's resolved
    // type (sema sets it to the pointee).
    if (node.lhs.nodeKind == XTASTNodeKindUnaryExpr && ((XTUnaryExprNode*)node.lhs).op == XTUnaryOpDeref)
        {
        XTUnaryExprNode* deref = (XTUnaryExprNode*)node.lhs;
        XTIRValue* ptr = [self lowerExpression:deref.operand];
        if (!ptr)
            return nil;
        XTIRValue* rhsVal = [self lowerExpression:node.rhs];
        if (!rhsVal)
            return nil;
        // Coerce RHS to the pointee type. node.lhs.resolvedType (sema's pointee)
        // is arch-dependent and WRONG for `@(p ± N)` — sema reports the byte
        // element for an 8-byte-pointer target while the pointer is really
        // u16/etc. The IR pointer carries the correct pointee (lowerPtrArithmetic
        // types the ElementAddr from the base pointer), so when the AST width
        // disagrees with it, store at the IR pointee's width instead.
        XTType* pointeeAST = node.lhs.resolvedType;
        XTIRType* pointeeIR = (ptr.type && ptr.type.kind == XTIRTypeKindPtr)
                                  ? ptr.type.pointeeType
                                  : nil;
        if (pointeeIR && pointeeIR.byteWidth > 0 && pointeeAST && pointeeAST.byteWidth != pointeeIR.byteWidth && rhsVal.type && rhsVal.type.byteWidth > 0)
            {
            if (rhsVal.type.byteWidth > pointeeIR.byteWidth)
                rhsVal = [self emitInsnOpcode:XTIROpTrunc
                                       result:pointeeIR
                                     operands:@[ [XTIROperand useWithValueId:rhsVal.valueId] ]];
            else if (rhsVal.type.byteWidth < pointeeIR.byteWidth)
                rhsVal = [self emitInsnOpcode:XTIROpZExt
                                       result:pointeeIR
                                     operands:@[ [XTIROperand useWithValueId:rhsVal.valueId] ]];
            }
        else if (pointeeAST)
            {
            rhsVal = [self coerceValue:rhsVal
                              fromType:node.rhs.resolvedType
                                toType:pointeeAST
                              location:node.location];
            }
        if (!rhsVal)
            return nil;

        // ARC store-through-a-pointer: same contract as a store to a strong
        // local or ivar — Retain the new value, Release the one already in the
        // slot. Without it every `T@@` out-parameter dangled: the callee's
        // owned local was released on return and the caller was left holding a
        // freed block, which usually still READS correctly (the bytes survive
        // until something reuses them), so it looked like it worked. See
        // private:docs/bugs/034.
        //
        // Releasing the old value is safe because class-pointer slots are
        // zero-initialised — an out-parameter points at a local or an ivar, and
        // both start null, so the first write releases nothing.
        XTIRType* slotIR = (pointeeIR && pointeeIR.byteWidth > 0)
                               ? pointeeIR
                               : [self irTypeForASTType:pointeeAST at:node.location];
        if (slotIR && [self astTypeIsClassPointer:pointeeAST])
            {
            XTIRValue* oldVal = [self emitLoad:ptr pointeeType:slotIR];
            if ([self arcRhsIsBorrowed:node.rhs])
                {
                if ([self astTypeIsAnyClassPointer:node.rhs.resolvedType])
                    [self emitRetain:rhsVal];
                }
            else
                {
                [self consumeOwnedTemp:rhsVal]; // +1 RHS adopted by the slot
                }
            [self emitRelease:oldVal];
            }

        [self emitStore:ptr value:rhsVal];
        return rhsVal;
        }
    if (node.lhs.nodeKind != XTASTNodeKindIdentifier)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: only simple-identifier or member-access LHS supported"];
        return nil;
        }
    XTIdentifierNode* lhs = (XTIdentifierNode*)node.lhs;

        // Pinned-local write: emit AddrOf + Store, skip SSA rebinding.
        {
        XTIRPinnedLocal* pl = self.pinnedLocals[lhs.identName];
        if (pl)
            {
            // Value-class copy-assign from a `recv.clone()` with no
            // user-defined clone on recv's class — emit field-by-field
            // copy from recv's slot into the LHS slot. Mirrors the
            // lowerVarDecl decl-init clone intercept.
            if (pl.type.kind == XTIRTypeKindAgg && node.rhs.nodeKind == XTASTNodeKindMethodCallExpr)
                {
                XTMethodCallExprNode* call = (XTMethodCallExprNode*)node.rhs;
                XTIRClassInfo* vci = self.valueClassLocals[lhs.identName];
                if (vci && [call.methodName isEqualToString:@"clone"] && call.arguments.count == 0)
                    {
                    XTType* rcvT = call.receiver.resolvedType;
                    XTType* rcvPointee = rcvT;
                    if (rcvT && [rcvT isKindOfClass:[XTPointerType class]])
                        rcvPointee = ((XTPointerType*)rcvT).pointeeType;
                    XTIRClassInfo* rcvCi = rcvPointee
                                               ? self.classesByName[rcvPointee.displayName]
                                               : nil;
                    BOOL hasUserClone = NO;
                    for (XTIRClassInfo* c = rcvCi; c != nil; c = c.parent)
                        {
                        NSString* cs = [NSString stringWithFormat:@"%@$clone", c.className];
                        if ([self.module symbolForName:cs])
                            {
                            hasUserClone = YES;
                            break;
                            }
                        }
                    if (rcvCi && !hasUserClone)
                        {
                        XTIRValue* srcAddr = [self lowerExpression:call.receiver];
                        if (srcAddr)
                            {
                            XTIRValue* dstAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                               result:vci.selfPtrType
                                                             operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                            XTIRLayout* layout = vci.instanceLayout;
                            for (NSUInteger i = 0; i < layout.fields.count; i++)
                                {
                                XTIRType* fieldTy = layout.fields[i].type;
                                XTIRType* fieldPtrTy = [XTIRType ptrToType:fieldTy
                                                                    window:XTIRWindowUnbanked];
                                XTIRValue* srcFa = [self emitFieldAddr:srcAddr
                                                            fieldIndex:i
                                                            resultType:fieldPtrTy];
                                XTIRValue* srcVal = [self emitLoad:srcFa pointeeType:fieldTy];
                                XTIRValue* dstFa = [self emitFieldAddr:dstAddr
                                                            fieldIndex:i
                                                            resultType:fieldPtrTy];
                                [self emitStore:dstFa value:srcVal];
                                }
                            return nil; // void-ish assignment result
                            }
                        }
                    }
                }
            // Aggregate brace-init copy-assign (`s = {…}`, `a = {…}` where
            // s is a struct / a is an array): emit field- or element-wise
            // Stores into the pinned slot, same path the var-decl init
            // uses. No single scalar value to coerce.
            if (node.rhs.nodeKind == XTASTNodeKindBlock && node.lhs.resolvedType && (node.lhs.resolvedType.kind == XTTypeKindArray || node.lhs.resolvedType.kind == XTTypeKindStruct))
                {
                [self lowerAggregateByteListInit:(XTBlockNode*)node.rhs
                                          pinned:pl
                                        declType:node.lhs.resolvedType
                                        location:node.location];
                return nil;
                }
            // `b = recv.method()` where the method returns a class value
            // and the LHS is a class-value pinned local — mirror of the
            // lowerVarDecl decl-init branch. The method returns a Ptr(C)
            // to its just-computed instance; field-copy from `*rhsVal`
            // into the LHS slot. Without this branch, the fall-through
            // `emitStore(addr, rhsVal)` writes the pointer VALUE into
            // the LHS slot's first 8 bytes, leaving the real ivar bytes
            // garbage (stack_class T13 BumpedPoint copy-assign,
            // T16 Big copy-assign through addAll). The user-clone /
            // non-clone-method cases collapse here uniformly — the
            // earlier no-user-clone field-copy short-circuit doesn't
            // fire when a user method is in play.
            if (pl.type.kind == XTIRTypeKindAgg && node.rhs.nodeKind == XTASTNodeKindMethodCallExpr)
                {
                XTIRClassInfo* vci = self.valueClassLocals[lhs.identName];
                if (vci)
                    {
                    XTIRValue* srcAddr = [self lowerExpression:node.rhs];
                    if (srcAddr && srcAddr.type.kind == XTIRTypeKindPtr)
                        {
                        XTIRValue* dstAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                           result:vci.selfPtrType
                                                         operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                        XTIRLayout* layout = vci.instanceLayout;
                        for (NSUInteger i = 0; i < layout.fields.count; i++)
                            {
                            XTIRType* fieldTy = layout.fields[i].type;
                            XTIRType* fieldPtrTy = [XTIRType ptrToType:fieldTy
                                                                window:XTIRWindowUnbanked];
                            XTIRValue* srcFa = [self emitFieldAddr:srcAddr
                                                        fieldIndex:i
                                                        resultType:fieldPtrTy];
                            XTIRValue* srcVal = [self emitLoad:srcFa pointeeType:fieldTy];
                            XTIRValue* dstFa = [self emitFieldAddr:dstAddr
                                                        fieldIndex:i
                                                        resultType:fieldPtrTy];
                            [self emitStore:dstFa value:srcVal];
                            }
                        return nil;
                        }
                    }
                }
            // Struct copy-assign with embedded strong class pointers: refcount
            // the pointees. Classify BEFORE evaluating the RHS — an OWNED
            // struct-returning call may RVO its sret straight into `dst`, so a
            // release-of-old emitted AFTER the RHS would free the NEW value and
            // the callee's zero-init would leak the old (xt6502 arc_struct_return).
            XTStructType* copySt = self.strongStructLocals[lhs.identName];
            BOOL borrowedStructCopy = copySt && [self arcRhsIsBorrowed:node.rhs] && (node.rhs.nodeKind == XTASTNodeKindIdentifier || node.rhs.nodeKind == XTASTNodeKindMemberAccess);
            if (copySt && !borrowedStructCopy)
                {
                // OWNED rhs (maker/return, already +1): release dst's prior
                // occupants NOW (before the RHS that may RVO into dst) and null
                // them so a RVO'd callee's zero-init can't leak them; dst then
                // adopts the +1 fields via the store below.
                [self emitStructStrongFieldReleaseForLocalNamed:lhs.identName];
                [self emitStructStrongFieldZeroInitForLocalNamed:lhs.identName];
                }
            XTIRValue* rhsVal = [self lowerExpression:node.rhs];
            if (!rhsVal)
                return nil;
            if (node.lhs.resolvedType)
                {
                rhsVal = [self coerceValue:rhsVal
                                  fromType:node.rhs.resolvedType
                                    toType:node.lhs.resolvedType
                                  location:node.location];
                }
            // Weak local: the payload sits past two hidden link words. See pinnedAddr:.
            XTIRType* ptrTy = nil;
            XTIRValue* addr = [self pinnedAddr:pl name:lhs.identName outType:&ptrTy];
            if (!addr)
                return nil;
            if (borrowedStructCopy)
                {
                // BORROWED rhs (`dst = src`): dst gains a 2nd ref to src's strong
                // fields. Retain them FIRST (self-copy `s = s` safe), then
                // release dst's old.
                XTIRValue* srcAddr = [self addressOfStructLValue:node.rhs];
                if (srcAddr)
                    [self emitStructStrongFieldRetainAt:srcAddr structType:copySt];
                [self emitStructStrongFieldReleaseForLocalNamed:lhs.identName];
                }
            [self emitStore:addr value:rhsVal];
            // `b = a;` between structs is the same wholesale copy as `S b = a;`
            // — link words included, destination linked to nothing.
            [self relinkWeakSlotsAfterCopyAt:addr astType:node.lhs.resolvedType];
            // Weak local (`weak:T@` or a `^`): re-point the side-table entry so
            // the slot auto-zeroes when the NEW target dies.
            [self emitWeakLocalRegisterNamed:lhs.identName value:rhsVal rhsNode:node.rhs];
            // Same as the weak-local DECL (bug 153): a weak local does not own
            // its referent, so a +1 RHS the store adopted must be released here,
            // after the re-register. A borrowed RHS owns nothing.
            if ([self astTypeIsWeakClassPointer:node.lhs.resolvedType] && ![self arcRhsIsBorrowed:node.rhs])
                [self emitRelease:rhsVal];
            return rhsVal;
            }
        }

    // Ivar reference shorthand (bare identifier that names an ivar) —
    // route through the same field-store path so writes hit memory.
    if (self.currentClassInfo && self.currentSelf)
        {
        for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
            {
            if (ci.ivarFieldIndex[lhs.identName])
                {
                return [self lowerIvarStoreNamed:lhs.identName
                                             rhs:node.rhs
                                        location:node.location];
                }
            }
        }

    // Module-level global write: AddrOf %sym + Store. Skips any SSA
    // locals rebinding — globals are real memory.
    NSNumber* gid = self.globalsByName[lhs.identName];
    if (gid && !self.locals[lhs.identName])
        {
        XTIRSymbol* sym = [self.module symbolForId:gid.unsignedIntegerValue];
        if (!sym)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: global '%@' lost its symbol", lhs.identName]];
            return nil;
            }
        XTIRValue* rhsValG = [self lowerExpression:node.rhs];
        if (!rhsValG)
            return nil;
        if (node.lhs.resolvedType)
            {
            rhsValG = [self coerceValue:rhsValG
                               fromType:node.rhs.resolvedType
                                 toType:node.lhs.resolvedType
                               location:node.location];
            }
        // Weak global: payload sits past the hidden link words.
        XTIRType* ptrTy = nil;
        XTIRValue* addr = [self globalPayloadAddr:sym
                                         symbolId:gid.unsignedIntegerValue
                                          outType:&ptrTy];
        if (!addr)
            return nil;

        // ARC: a strong class-pointer global behaves like a strong local
        // / ivar — load the old value, retain the new (borrowed RHS),
        // release the old, then store. Without this, reassigning a
        // strong global leaks the previous object (its dealloc never
        // fires). Mirrors lowerMemberAssign's strong-ivar dance.
        if ([self astTypeIsClassPointer:node.lhs.resolvedType])
            {
            XTIRValue* oldVal = [self emitLoad:addr pointeeType:ptrTy]; // payload type
            if ([self arcRhsIsBorrowed:node.rhs])
                {
                if ([self astTypeIsAnyClassPointer:node.rhs.resolvedType])
                    [self emitRetain:rhsValG];
                }
            else
                {
                [self consumeOwnedTemp:rhsValG]; // +1 RHS adopted by the global
                }
            [self emitRelease:oldVal];
            }

        [self emitStore:addr value:rhsValG];
        // Weak global (`weak:T@ g;`): register the slot in the side-table so the
        // pointee's dealloc auto-zeroes it — mirrors the weak-IVAR path. Without
        // this a weak global stayed a dangling pointer after its target was
        // freed (weak_basic T2 failed; only the ivar path registered). A
        // re-point unregisters the prior entry first; a null RHS just unregisters.
        if ([self astTypeIsWeakClassPointer:node.lhs.resolvedType])
            {
            [self emitWeakUnregisterSlot:addr];
            [self emitWeakRegisterSlot:addr obj:rhsValG];
            // Balance a +1 RHS the weak slot doesn't own (bug 170, global
            // sibling of 153). See the local-decl and array-element notes.
            if (![self arcRhsIsBorrowed:node.rhs])
                [self emitRelease:rhsValG];
            }
        // Same for a bound-method (`^`) GLOBAL — see the array-element note.
        if (node.lhs.resolvedType.boundMethodSignature != nil)
            {
            [self emitWeakBoundRegisterAt:addr
                                    value:rhsValG
                                boundType:node.lhs.resolvedType
                                  rhsNode:node.rhs];
            }
        return rhsValG;
        }

    XTIRValue* rhsVal = [self lowerExpression:node.rhs];
    if (!rhsVal)
        return nil;
    XTIRValue* existing = self.locals[lhs.identName];
    if (existing && node.rhs.resolvedType && existing.type)
        {
        XTType* dstAST = node.lhs.resolvedType;
        if (dstAST)
            {
            rhsVal = [self coerceValue:rhsVal
                              fromType:node.rhs.resolvedType
                                toType:dstAST
                              location:node.location];
            }
        }

    // ARC: assignment to a strong class-pointer local releases the
    // old value and retains the new (per the language's ARC rules). The
    // retain is skipped when the RHS is value-producing (`new T()`,
    // a Call returning a fresh +1 reference, an explicit (T@)null
    // cast). Borrowed RHS (identifier / member / cast through a
    // pointer) does require a retain.
    if ([self.strongLocals containsObject:lhs.identName] && existing)
        {
        if ([self arcRhsIsBorrowed:node.rhs])
            {
            if ([self astTypeIsAnyClassPointer:node.rhs.resolvedType])
                [self emitRetain:rhsVal];
            }
        else
            {
            // +1 RHS (new / returnsRetained call): the slot adopts the
            // owned temp — drop it from the end-of-full-expr sweep (#123).
            [self consumeOwnedTemp:rhsVal];
            }
        [self emitRelease:existing];
        }
    else if ([self astTypeIsClassPointer:node.lhs.resolvedType] && [self.strongLocals containsObject:lhs.identName])
        {
        // First assignment to a strong slot — no old value to release.
        if ([self arcRhsIsBorrowed:node.rhs])
            {
            if ([self astTypeIsAnyClassPointer:node.rhs.resolvedType])
                [self emitRetain:rhsVal];
            }
        else
            {
            [self consumeOwnedTemp:rhsVal];
            }
        }

    // Binding a +1 temp to ANY SSA local (including a non-strong slot or
    // a reassigned parameter, e.g. `p = new Item()` then `… p.id`) means
    // the local now references it — it must not be released by the
    // end-of-full-expression sweep (#123). A strong slot already consumed
    // above; this also covers the non-strong / param-rebind cases, where
    // the worst case is a leak (the pre-#123 status quo) rather than the
    // use-after-free a stray release would cause.
    [self consumeOwnedTemp:rhsVal];
    self.locals[lhs.identName] = rhsVal;
    return rhsVal;
    }

// Helper: store into a class/struct field. Handles both the plain
// "compute FieldAddr, then Store" sequence and the ARC strong-slot
// dance (release old field value if the slot is a strong class
// pointer, retain the new value when the RHS is a borrowed reference).
- (nullable XTIRValue*)lowerMemberAssign:(XTMemberAccessNode*)lhs
                                     rhs:(XTASTNode*)rhsNode
                                location:(XTSourceLocation*)loc
    {
    // Resolve the receiver's class info from the base's resolved type.
    // The base is either a plain identifier (`obj`), `self`, or another
    // member-access. Sema gives every base a pointer-to-class type for
    // class members; we walk through pointers to land on the class
    // marker.
    XTASTNode* base = lhs.base;
    XTType* baseType = base.resolvedType;
    XTType* pointeeAST = baseType;
    if (baseType && [baseType isKindOfClass:[XTPointerType class]])
        {
        pointeeAST = ((XTPointerType*)baseType).pointeeType;
        }
    // Struct-typed base — no ARC dance (struct fields aren't class
    // refs); just FieldAddr + Store.
    if (pointeeAST && pointeeAST.kind == XTTypeKindStruct && [pointeeAST isKindOfClass:[XTStructType class]])
        {
        XTStructType* st = (XTStructType*)pointeeAST;
        NSUInteger fieldIndex = 0;
        XTType* fieldAST = nil;
        if (![self structType:st
                   fieldNamed:lhs.memberName
                        index:&fieldIndex
                      astType:&fieldAST])
            {
            [self softFailLoweringAt:loc
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: struct '%@' has no field '%@'",
                                                   pointeeAST.displayName, lhs.memberName]];
            return nil;
            }
        // Arrow form when `->` OR the base is already a pointer to the struct
        // (`s.w = …` where `s` is `gfx_surface@`): the base value is the address.
        BOOL baseIsPointer = (baseType && [baseType isKindOfClass:[XTPointerType class]]);
        XTIRValue* baseAddr = nil;
        if (lhs.isArrow || baseIsPointer)
            {
            baseAddr = [self lowerExpression:base];
            }
        else
            {
            baseAddr = [self addressOfStructLValue:base];
            }
        if (!baseAddr)
            return nil;
        XTIRValue* rhsVal = [self lowerExpression:rhsNode];
        if (!rhsVal)
            return nil;
        rhsVal = [self coerceValue:rhsVal
                          fromType:rhsNode.resolvedType
                            toType:fieldAST
                          location:loc];
        XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:loc];
        if (!fieldIRType)
            return nil;
        XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
        XTIRValue* fa = [self emitFieldAddr:baseAddr
                                 fieldIndex:fieldIndex
                                 resultType:fieldPtrType];
        // A struct field CAN be a strong class pointer (`struct H { Item@ p; }`)
        // — it owns the pointee like a class ivar: reassigning it releases the
        // old occupant and retains a borrowed RHS (or adopts a +1 temp). GATED
        // to a flat struct LOCAL base (`localVar.field = …`): only those are
        // zero-inited + torn down at scope exit, so the release-of-old reads a
        // valid null/pointer. Other bases (array elems, nested, params) aren't
        // zero-inited — releasing their garbage would segfault — so they fall
        // back to a plain store (the prior no-ARC behaviour).
        // Enabled when the field's base roots at a tracked, recursively zero-
        // inited struct local — flat (`s.f`), nested (`o.mid.leaf`), or struct-
        // array element (`harr[i].payload`). Other bases (params, untracked)
        // fall back to a plain store.
        BOOL baseIsTrackedStructLocal = [self structFieldBaseIsTrackedLocal:base];
        if (baseIsTrackedStructLocal && [self astTypeIsClassPointer:fieldAST])
            {
            XTIRValue* oldVal = [self emitLoad:fa pointeeType:fieldIRType];
            if ([self arcRhsIsBorrowed:rhsNode])
                {
                if ([self astTypeIsAnyClassPointer:rhsNode.resolvedType])
                    [self emitRetain:rhsVal];
                }
            else
                {
                [self consumeOwnedTemp:rhsVal];
                }
            [self emitRelease:oldVal];
            }
        [self emitStore:fa value:rhsVal];
        // A weak STRUCT FIELD is an auto-zeroing slot: link it into the
        // referent's chain. The `baseIsTrackedStructLocal` gate is dropped for
        // the `^` case — a bound method in ANY struct lvalue must be linked, or
        // `if (h.action)` stays true after the receiver dies.
        if (baseIsTrackedStructLocal && [self astTypeIsWeakClassPointer:fieldAST])
            {
            [self emitWeakUnregisterSlot:fa];
            [self emitWeakRegisterSlot:fa obj:rhsVal];
            // Balance a +1 RHS the weak slot doesn't own (bug 170). See the
            // local-decl note.
            if (![self arcRhsIsBorrowed:rhsNode])
                [self emitRelease:rhsVal];
            }
        if (fieldAST.boundMethodSignature != nil)
            {
            [self emitWeakBoundRegisterAt:fa
                                    value:rhsVal
                                boundType:fieldAST
                                  rhsNode:rhsNode];
            }
        return rhsVal;
        }
    if (!pointeeAST || pointeeAST.kind != XTTypeKindClass)
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: only class-member assignments supported on member LHS"];
        return nil;
        }
    XTIRClassInfo* baseCi = self.classesByName[pointeeAST.displayName];
    if (!baseCi)
        {
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unknown class '%@' for member store", pointeeAST.displayName]];
        return nil;
        }

    NSNumber* slot = nil;
    XTType* ivarAST = nil;
    for (XTIRClassInfo* ci = baseCi; ci != nil; ci = ci.parent)
        {
        slot = ci.ivarFieldIndex[lhs.memberName];
        if (slot)
            {
            ivarAST = ci.ivarASTType[lhs.memberName];
            break;
            }
        }
    if (!slot || !ivarAST)
        {
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: class '%@' has no ivar '%@'",
                                               pointeeAST.displayName, lhs.memberName]];
        return nil;
        }

    XTIRValue* basePtr = [self selfPointerForClassBase:base];
    if (!basePtr)
        return nil;
    XTIRValue* rhsVal = [self lowerExpression:rhsNode];
    if (!rhsVal)
        return nil;

    if (ivarAST)
        {
        rhsVal = [self coerceValue:rhsVal
                          fromType:rhsNode.resolvedType
                            toType:ivarAST
                          location:loc];
        }

    XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:loc];
    if (!fieldIRType)
        return nil;
    XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
    XTIRValue* fa = [self emitFieldAddr:basePtr
                             fieldIndex:slot.unsignedIntegerValue
                             resultType:fieldPtrType];

    // ARC ivar-store: load the old value and Release it if the field
    // is a strong class pointer; Retain the new value when the RHS is
    // a borrowed reference. The "is strong" check is the same
    // class-pointer predicate used for locals.
    BOOL strongIvar = [self astTypeIsClassPointer:ivarAST];
    if (strongIvar)
        {
        XTIRValue* oldVal = [self emitLoad:fa pointeeType:fieldIRType];
        if ([self arcRhsIsBorrowed:rhsNode])
            {
            if ([self astTypeIsAnyClassPointer:rhsNode.resolvedType])
                [self emitRetain:rhsVal];
            }
        else
            {
            [self consumeOwnedTemp:rhsVal]; // +1 RHS adopted by the ivar (#123)
            }
        [self emitRelease:oldVal];
        }

    [self emitStore:fa value:rhsVal];

    // Weak ivar (`weak:T@`): no retain (weak doesn't own), but the
    // side-table must learn the new (obj → slot) mapping so the pointee's
    // dealloc zeroes this slot. Drop any prior registration for the slot
    // first (a re-point), then register the new value. A null RHS just
    // unregisters (the runtime register skips a null obj). private:docs/bugs/011 #6.
    if ([self astTypeIsWeakClassPointer:ivarAST])
        {
        [self emitWeakUnregisterSlot:fa];
        [self emitWeakRegisterSlot:fa obj:rhsVal];
        // Balance a +1 RHS the weak slot doesn't own (bug 170, the ivar
        // sibling of 153). Mirrors the local-decl release.
        if (![self arcRhsIsBorrowed:rhsNode])
            [self emitRelease:rhsVal];
        }
    // Weak bound method (`weak:action_t^ action;`) — the control's action slot.
    // Registers the CODE word, and skips a widened function pointer. See
    // emitWeakBoundRegisterAt:.
    if ([self astTypeIsWeakBound:ivarAST])
        {
        [self emitWeakBoundRegisterAt:fa value:rhsVal boundType:ivarAST rhsNode:rhsNode];
        }
    return rhsVal;
    }

#pragma mark - Cast

// Stamp the RTTI class-id into a freshly-`new`-ed instance's slot-0 word
// so a later downcast can read the dynamic type. Only for NON-vtable
// classes: a vtable class uses slot 0 for its vtable pointer
// (emitVtableInitFor:), and nothing reads slot 0 of a non-vtable class,
// so the word is free. The store goes through a Ptr(u16) bitcast of the
// instance (preserving the bank byte), so it lands in the object's heap
// bank. (A vtable-class instance can't currently be a downcast source —
// its slot 0 is the vtable ptr, not an id; no fixture needs that.)
- (void)emitClassIdStampFor:(XTIRValue*)instance class:(nullable XTIRClassInfo*)ci
    {
    if (!ci || !instance || ci.needsVtable || ci.classId == 0)
        return;
    XTIRType* u16 = [XTIRType u16Type];
    XTIRType* u16Ptr = [XTIRType ptrToType:u16 window:XTIRWindowUnbanked];
    XTIRValue* idAddr = [self emitInsnOpcode:XTIROpBitcast
                                      result:u16Ptr
                                    operands:@[ [XTIROperand useWithValueId:instance.valueId] ]];
    [self emitStore:idAddr value:[self emitU16Const:(uint32_t)ci.classId]];
    }

// Lower a class downcast `(T@) p` / `(T@ ?) p` as a runtime subtree-id
// check, entirely in IR (no backend support needed). The dynamic class
// id is read from the instance's slot-0 word and tested against the set
// of ids in T's subtree (T plus every descendant). A match yields the
// pointer (bitcast to T@); a miss yields null (failable) or traps
// (plain). A null operand passes through as null for both flavours — the
// id load on a null pointer reads address 0 (harmless on both backends),
// and the explicit null check folds into the match condition so the
// result is null regardless.
// YES if `root` and every class that descends from it are non-vtable, so
// each instance's slot-0 word reliably holds the stamped class id (rather
// than a vtable pointer). The downcast id-check is only sound under this
// condition; otherwise it must fall back to a pass-through bitcast.
- (BOOL)subtreeAllNonVtable:(XTIRClassInfo*)root
    {
    if (!root)
        return NO;
    for (NSString* cn in self.classDeclsByName)
        {
        for (XTIRClassInfo* c = self.classesByName[cn]; c != nil; c = c.parent)
            {
            if (c == root)
                {
                if (self.classesByName[cn].needsVtable)
                    return NO;
                break;
                }
            }
        }
    return !root.needsVtable;
    }

- (nullable XTIRValue*)lowerClassDowncastFrom:(XTIRValue*)src
                                  sourceClass:(nullable XTIRClassInfo*)sourceCi
                                  targetClass:(XTIRClassInfo*)targetCi
                                   resultType:(XTIRType*)resultIR
                                     failable:(BOOL)failable
    {
    // Collect the target's subtree: target + every descendant. Sorted
    // names, NOT dictionary order — the OR-chain of vtable compares this
    // feeds is otherwise emitted in hash order (the fourth such leak the
    // selfhost differentials have caught; see project_hash_order_leaks).
    NSMutableArray<XTIRClassInfo*>* subtree = [NSMutableArray array];
    NSArray<NSString*>* subtreeNames =
        [self.classDeclsByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* cn in subtreeNames)
        {
        for (XTIRClassInfo* c = self.classesByName[cn]; c != nil; c = c.parent)
            {
            if (c == targetCi)
                {
                [subtree addObject:self.classesByName[cn]];
                break;
                }
            }
        }

    // Pick the slot-0 discriminator to match how `new` tagged the instance:
    //   - source subtree all non-vtable → slot 0 holds the class id (idMode).
    //   - otherwise, if the TARGET is a vtable class (or the source is) → slot 0 is
    //     a vtable pointer and we WALK its parent chain (vtblMode). Target-driven,
    //     not just source-driven: the common cross-module cast erases the operand to
    //     `Object@` (e.g. `viewAt` → `(XGView@ ?)`), so `sourceCi` is often nil —
    //     but a vtable target means a matching object carries a vtable, which is all
    //     the walk needs. (Every class rooted at a vtable Object is itself vtable.)
    //   - target non-vtable with an unknown source → pass-through (valid by
    //     construction at the call site).
    BOOL idMode = [self subtreeAllNonVtable:sourceCi];
    BOOL vtblMode = !idMode && (targetCi.needsVtable || (sourceCi && sourceCi.needsVtable));
    if (!idMode && !vtblMode)
        {
        return [self emitInsnOpcode:XTIROpBitcast
                             result:resultIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }

    XTIRType* u16 = [XTIRType u16Type];
    XTIRType* boolTy = [XTIRType boolType];
    XTIRType* voidPtr = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    // On xt6502 a pointer is 3 bytes ([addr-lo, addr-hi, bank]); a vtable is uniquely
    // identified by its 2-byte ADDRESS (all vtables share the data window), so the
    // identity compare must PtrToInt→u16 and drop the bank byte. Flat targets (m68k 4,
    // arm* / x86_64 8) compare the whole pointer (Task #620 — full width, no aliasing).
    BOOL bankedPtr = ([XTPointerType pointerToType:[XTType u8Type]].byteWidth == 3);

    // matchPtr (the value yielded on a hit) and nullPtr, both in pred.
    XTIRValue* matchPtr = [self emitInsnOpcode:XTIROpBitcast
                                        result:resultIR
                                      operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
    // Null pointer via Const #0:U16 → IntToPtr — the established
    // construction (see emitZeroInitIvarsFor:). A direct Const of Ptr type
    // is mis-sized by the arm64 backend (stored 32-bit, read 64-bit → the
    // high bytes are stack garbage → a bogus non-null pointer).
    XTIRValue* nullPtr = [self emitInsnOpcode:XTIROpIntToPtr
                                       result:resultIR
                                     operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];

    // ── Null check FIRST, before any deref ───────────────────────────
    // A null source passes through as null for BOTH the failable and the
    // plain cast, so the slot-0 discriminator must never be loaded from a
    // null pointer. (On the 6502 a null deref reads harmless ZP garbage;
    // on a flat host — arm64 — it faults. The id/vtable load therefore
    // lives behind a non-null branch, correct for every backend and with
    // no reliance on an address sandbox.)
    // Whole-pointer null test (not PtrToInt→u16, which reads a 64 KB-aligned object
    // as null on a 32/64-bit target). IntToPtr(#0) builds the null — a direct Ptr
    // Const is mis-sized on arm64 (see nullPtr above).
    XTIRValue* isNull = [self allocateValueOfType:boolTy atSite:self.currentBlock];
    if (bankedPtr)
        {
        // Banked xt6502: a null object has address 0; test the 2-byte address (drop the
        // bank byte), matching the vtable-identity compare below.
        XTIRValue* srcAddr = [self emitInsnOpcode:XTIROpPtrToInt
                                           result:u16
                                         operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                       result:isNull
                                                                     operands:@[ [XTIROperand useWithValueId:srcAddr.valueId],
                                                                                 [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]
                                                                    predicate:XTIRICmpEQ
                                                                       dbgLoc:nil]];
        }
    else
        {
        XTIRValue* srcNull = [self emitInsnOpcode:XTIROpIntToPtr
                                           result:src.type
                                         operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                       result:isNull
                                                                     operands:@[ [XTIROperand useWithValueId:src.valueId],
                                                                                 [XTIROperand useWithValueId:srcNull.valueId] ]
                                                                    predicate:XTIRICmpEQ
                                                                       dbgLoc:nil]];
        }

    XTIRBlock* predBlock = self.currentBlock;
    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* checkBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_check"]];
    XTIRBlock* missBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_miss"]];
    XTIRBlock* joinBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_join"]];

    // null → join (yields null); non-null → check (safe to read slot 0).
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:isNull.valueId],
                            [XTIROperand blockWithRef:joinBlock],
                            [XTIROperand blockWithRef:checkBlock] ]];

    // ── checkBlock: source is non-null; discriminate the dynamic class ──
    self.currentBlock = checkBlock;
    XTIRValue* preToken = self.memToken; // read-only walk: restore after, so no
                                         // loop-carried memory token flows forward.
    XTIRBlock* matchEdge = checkBlock;   // block whose join edge yields matchPtr
    BOOL matchReachesJoin = NO;

    if (idMode)
        {
        // Non-vtable classes carry a dense class id in slot 0. OR over the
        // compile-time subtree — these never cross a module boundary with RTTI, so
        // the static descendant set is complete.
        XTIRType* u16Ptr = [XTIRType ptrToType:u16 window:XTIRWindowUnbanked];
        XTIRValue* idAddr = [self emitInsnOpcode:XTIROpBitcast
                                          result:u16Ptr
                                        operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        XTIRValue* dynKey = [self emitLoad:idAddr pointeeType:u16];
        XTIRValue* matched = nil;
        for (XTIRClassInfo* c in subtree)
            {
            if (c.classId == 0)
                continue;
            XTIRValue* keyC = [self emitU16Const:(uint32_t)c.classId];
            XTIRValue* eq = [self allocateValueOfType:boolTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                           result:eq
                                                                         operands:@[ [XTIROperand useWithValueId:dynKey.valueId],
                                                                                     [XTIROperand useWithValueId:keyC.valueId] ]
                                                                        predicate:XTIRICmpEQ
                                                                           dbgLoc:nil]];
            matched = matched ? [self emitInsnOpcode:XTIROpOr
                                              result:boolTy
                                            operands:@[ [XTIROperand useWithValueId:matched.valueId],
                                                        [XTIROperand useWithValueId:eq.valueId] ]]
                              : eq;
            }
        if (matched)
            {
            matchReachesJoin = YES;
            [self emitTerminator:XTIROpCondBranch
                        operands:@[ [XTIROperand useWithValueId:matched.valueId],
                                    [XTIROperand blockWithRef:joinBlock],
                                    [XTIROperand blockWithRef:missBlock] ]];
            }
        else
            {
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:missBlock] ]];
            }
        }
    else if (!targetCi.needsVtable)
        {
        // vtblMode reached via a vtable SOURCE, but the target class has no vtable of
        // its own — nothing in the object's vtable chain can equal it. (Symbol id 0 is
        // a VALID id, so this must gate on needsVtable, not vtableSymbolId == 0.)
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:missBlock] ]];
        }
    else if (!sVtableAncestry)
        {
        // No parent link in the vtable (xt6502/m68k: single-module, no `.so`). Fall
        // back to the compile-time subtree: OR the object's vtable pointer against
        // every descendant's vtable address. Complete because these targets can't
        // receive a subclass from another module. Full-pointer compare (Task #620).
        XTIRType* vtblPtrPtr = [XTIRType ptrToType:voidPtr window:XTIRWindowUnbanked];
        XTIRValue* slot0 = [self emitInsnOpcode:XTIROpBitcast
                                         result:vtblPtrPtr
                                       operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        XTIRValue* dynKey = [self emitLoad:slot0 pointeeType:voidPtr];
        if (bankedPtr)
            dynKey = [self emitInsnOpcode:XTIROpPtrToInt
                                   result:u16
                                 operands:@[ [XTIROperand useWithValueId:dynKey.valueId] ]];
        XTIRValue* matched = nil;
        for (XTIRClassInfo* c in subtree)
            {
            if (!c.needsVtable)
                continue;
            XTIRValue* keyC = [self emitInsnOpcode:XTIROpAddrOf
                                            result:voidPtr
                                          operands:@[ [XTIROperand symWithSymbolId:c.vtableSymbolId] ]];
            if (bankedPtr)
                keyC = [self emitInsnOpcode:XTIROpPtrToInt
                                     result:u16
                                   operands:@[ [XTIROperand useWithValueId:keyC.valueId] ]];
            XTIRValue* eq = [self allocateValueOfType:boolTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                           result:eq
                                                                         operands:@[ [XTIROperand useWithValueId:dynKey.valueId],
                                                                                     [XTIROperand useWithValueId:keyC.valueId] ]
                                                                        predicate:XTIRICmpEQ
                                                                           dbgLoc:nil]];
            matched = matched ? [self emitInsnOpcode:XTIROpOr
                                              result:boolTy
                                            operands:@[ [XTIROperand useWithValueId:matched.valueId],
                                                        [XTIROperand useWithValueId:eq.valueId] ]]
                              : eq;
            }
        if (matched)
            {
            matchReachesJoin = YES;
            [self emitTerminator:XTIROpCondBranch
                        operands:@[ [XTIROperand useWithValueId:matched.valueId],
                                    [XTIROperand blockWithRef:joinBlock],
                                    [XTIROperand blockWithRef:missBlock] ]];
            }
        else
            {
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:missBlock] ]];
            }
        }
    else
        {
        // vtblMode: WALK the object's vtable-parent chain. Slot 0 of the object is
        // its own vtable; each vtable's ENTRY 0 is its parent's vtable ("" → null at
        // a root). Climbing to the target's vtable recognises a subclass defined in
        // ANY module — the compile-time subtree can't list a client's subclass, but
        // its vtable links up to this shared base. Full-pointer compares throughout.
        XTIRType* vtblPtrPtr = [XTIRType ptrToType:voidPtr window:XTIRWindowUnbanked];
        XTIRValue* slot0 = [self emitInsnOpcode:XTIROpBitcast
                                         result:vtblPtrPtr
                                       operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        XTIRValue* vtbl0 = [self emitLoad:slot0 pointeeType:voidPtr]; // obj's own vtable
        XTIRValue* target = [self emitInsnOpcode:XTIROpAddrOf
                                          result:voidPtr
                                        operands:@[ [XTIROperand symWithSymbolId:targetCi.vtableSymbolId] ]];
        XTIRValue* zeroP = [self emitInsnOpcode:XTIROpIntToPtr
                                         result:voidPtr
                                       operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];

        XTIRBlock* loopBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_loop"]];
        XTIRBlock* endChk = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_end"]];
        XTIRBlock* advBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_downcast_adv"]];

        // checkBlock → loop, carrying obj's own vtable.
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:loopBlock] ]];

        // Loop phi `p`: obj.vtbl on the entry edge, the parent link on the back edge.
        XTIRValueId pvid = [self.currentFunction allocateValueId];
        XTIRDefSite* psite = [[XTIRDefSite alloc] initWithBlock:loopBlock insnIndex:0];
        XTIRValue* p = [[XTIRValue alloc] initWithValueId:pvid type:voidPtr defSite:psite];
        [self.currentFunction registerValue:p];

        // advBlock: parent = *p (entry 0), then loop.
        self.currentBlock = advBlock;
        XTIRValue* pAsPP = [self emitInsnOpcode:XTIROpBitcast
                                         result:vtblPtrPtr
                                       operands:@[ [XTIROperand useWithValueId:p.valueId] ]];
        XTIRValue* pParent = [self emitLoad:pAsPP pointeeType:voidPtr];
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:loopBlock] ]];

        // loopBlock: p == target → match; else end-check.
        self.currentBlock = loopBlock;
        XTIRValue* isMatch = [self allocateValueOfType:boolTy atSite:loopBlock];
        [loopBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                               result:isMatch
                                                             operands:@[ [XTIROperand useWithValueId:p.valueId],
                                                                         [XTIROperand useWithValueId:target.valueId] ]
                                                            predicate:XTIRICmpEQ
                                                               dbgLoc:nil]];
        [self emitTerminator:XTIROpCondBranch
                    operands:@[ [XTIROperand useWithValueId:isMatch.valueId],
                                [XTIROperand blockWithRef:joinBlock],
                                [XTIROperand blockWithRef:endChk] ]];

        // endChk: p == null → miss (chain exhausted); else advance.
        self.currentBlock = endChk;
        XTIRValue* isEnd = [self allocateValueOfType:boolTy atSite:endChk];
        [endChk appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                            result:isEnd
                                                          operands:@[ [XTIROperand useWithValueId:p.valueId],
                                                                      [XTIROperand useWithValueId:zeroP.valueId] ]
                                                         predicate:XTIRICmpEQ
                                                            dbgLoc:nil]];
        [self emitTerminator:XTIROpCondBranch
                    operands:@[ [XTIROperand useWithValueId:isEnd.valueId],
                                [XTIROperand blockWithRef:missBlock],
                                [XTIROperand blockWithRef:advBlock] ]];

        // Loop phi operands (both predecessors — checkBlock entry, advBlock back edge).
        [loopBlock.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                                result:p
                                                              operands:@[ [XTIROperand blockWithRef:checkBlock],
                                                                          [XTIROperand useWithValueId:vtbl0.valueId],
                                                                          [XTIROperand blockWithRef:advBlock],
                                                                          [XTIROperand useWithValueId:pParent.valueId] ]
                                                                dbgLoc:nil]];

        matchEdge = loopBlock;
        matchReachesJoin = YES;
        }

    self.currentBlock = missBlock;
    BOOL missReachesJoin = failable;
    if (failable)
        {
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
        }
    else
        {
        // Plain `(T@)p` on a real (non-null) type mismatch is a hard error.
        [self emitTerminator:XTIROpUnreachable operands:@[]];
        }

    // ── joinBlock: phi over the reaching edges, ordered by block index ─
    //   predBlock  → nullPtr  (null source)
    //   matchEdge  → matchPtr (type matched — checkBlock in idMode, loop in vtblMode)
    //   missBlock  → nullPtr  (failable miss; absent when plain → trap)
    self.currentBlock = joinBlock;
    self.memToken = preToken; // pre-walk token dominates join; the walk wrote nothing.
    NSMutableArray<XTIRBlock*>* phiBlocks = [NSMutableArray array];
    NSMutableArray<XTIRValue*>* phiVals = [NSMutableArray array];
    [phiBlocks addObject:predBlock];
    [phiVals addObject:nullPtr];
    if (matchReachesJoin)
        {
        [phiBlocks addObject:matchEdge];
        [phiVals addObject:matchPtr];
        }
    if (missReachesJoin)
        {
        [phiBlocks addObject:missBlock];
        [phiVals addObject:nullPtr];
        }

    if (phiBlocks.count == 1)
        {
        // Only the null edge reaches join (a plain cast with no matchable
        // subtree). nullPtr dominates join → return it directly.
        [self retargetOwnedTempFrom:src to:nullPtr];
        return nullPtr;
        }
    NSMutableArray<NSNumber*>* order = [NSMutableArray array];
    for (NSUInteger i = 0; i < phiBlocks.count; i++)
        [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
      NSUInteger ia = [self.currentFunction.blocks indexOfObjectIdenticalTo:phiBlocks[a.unsignedIntegerValue]];
      NSUInteger ib = [self.currentFunction.blocks indexOfObjectIdenticalTo:phiBlocks[b.unsignedIntegerValue]];
      if (ia < ib)
          return NSOrderedAscending;
      if (ia > ib)
          return NSOrderedDescending;
      return NSOrderedSame;
    }];
    NSMutableArray<XTIROperand*>* phiOps = [NSMutableArray array];
    for (NSNumber* n in order)
        {
        NSUInteger i = n.unsignedIntegerValue;
        [phiOps addObject:[XTIROperand blockWithRef:phiBlocks[i]]];
        [phiOps addObject:[XTIROperand useWithValueId:phiVals[i].valueId]];
        }
    XTIRValueId vid = [self.currentFunction allocateValueId];
    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:joinBlock insnIndex:0];
    XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:resultIR defSite:site];
    [self.currentFunction registerValue:phiResult];
    [joinBlock.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                            result:phiResult
                                                          operands:phiOps
                                                            dbgLoc:nil]];
    // A +1 temporary that flowed IN flows OUT as this phi — retarget it, or the
    // end-of-statement sweep releases the pre-cast value while the phi is what
    // the caller bound. That freed the object under its owner: `Number@ n =
    // (Number@ ?)map.get(k);` crashed as soon as `map.get` became +1.
    [self retargetOwnedTempFrom:src to:phiResult];
    return phiResult;
    }

- (nullable XTIRValue*)lowerCastExpr:(XTCastExprNode*)node
    {
    XTIRValue* src = [self lowerExpression:node.operand];
    if (!src)
        return nil;
    XTType* srcType = node.operand.resolvedType;
    XTType* dstType = node.castType;
    XTIRType* dstIR = [self irTypeForASTType:dstType at:node.location];
    if (!dstIR)
        return nil;

    // Cast TO a bound method (`^`). This function's own conversions are all
    // scalar — ZExt / IntToPtr / Bitcast — and a `^` is a two-field aggregate,
    // so falling through to them zero-extended an integer straight into the
    // aggregate type and produced garbage. `(pred_t^)0` — the obvious way to
    // say "no callback" — crashed the moment it was tested or called.
    //
    // coerceValue: knows both cases: widening a plain function into a `^`, and
    // building the all-zero {recv, code} pair for a null one.
    if (dstType && dstType.boundMethodSignature != nil)
        {
        return [self coerceValue:src
                        fromType:srcType
                          toType:dstType
                        location:node.location];
        }

    // Cast a callback VALUE to a pointer/integer — `(pointer)f` on a callback
    // variable. Its code address is the recv word (field 0); delegate to
    // coerceValue, which extracts it. Falling through to the scalar path below
    // IntToPtr'd the whole 16-byte pair to garbage (c2xc 13). The designator
    // `(pointer)&fn` never reaches here — sema lowers it to the address directly.
    if (srcType && srcType.boundMethodSignature != nil && (!dstType || dstType.boundMethodSignature == nil))
        {
        return [self coerceValue:src
                        fromType:srcType
                          toType:dstType
                        location:node.location];
        }

    // Protocol conformance downcast — `(P@ ?) obj` / `(P@) obj` where sema stamped
    // `targetProtocolName` (the source isn't statically known to conform). Ask the
    // runtime helper whether obj's dynamic class carries P's id (it searches the
    // object's vtable itable); yield the pointer on a hit, null (failable) or a
    // trap (plain) on a miss. Cross-module correct: the id comes from the protocol
    // name, so a client class conforming to an imported protocol is recognised.
    if (node.targetProtocolName.length)
        {
        XTIRSymbol* hsym = [self.module symbolForName:@"_xtc_obj_conforms"];
        if (hsym && hsym.function)
            {
            XTIRSymbolId hid = [self.module.symbols indexOfObjectIdenticalTo:hsym];
            XTIRType* ptrVoid = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
            XTIRType* ptrPtrV = [XTIRType ptrToType:ptrVoid window:XTIRWindowUnbanked];
            XTIRType* boolTy = [XTIRType boolType];
            XTIRType* u32t = [XTIRType u32Type];

            XTIRValue* asP = [self emitInsnOpcode:XTIROpBitcast
                                           result:dstIR
                                         operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
            XTIRValue* nullP = [self emitInsnOpcode:XTIROpIntToPtr
                                             result:dstIR
                                           operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];

            // obj-null test — a null downcast is null, and we must not read obj[0].
            XTIRValue* srcNull = [self emitInsnOpcode:XTIROpIntToPtr
                                               result:src.type
                                             operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];
            XTIRValue* objIsNull = [self allocateValueOfType:boolTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                           result:objIsNull
                                                                         operands:@[ [XTIROperand useWithValueId:src.valueId],
                                                                                     [XTIROperand useWithValueId:srcNull.valueId] ]
                                                                        predicate:XTIRICmpEQ
                                                                           dbgLoc:nil]];
            XTIRValue* falseC = [self allocateValueOfType:boolTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                           result:falseC
                                                                         operands:@[ [XTIROperand immIWithType:boolTy value:0] ]
                                                                           dbgLoc:nil]];

            NSString* pfx = [NSString stringWithFormat:@"bb_%lu_protocast",
                                                       (unsigned long)self.currentFunction.blocks.count];
            XTIRBlock* entryBB = self.currentBlock;
            XTIRBlock* readBB = [self addBlockWithName:[pfx stringByAppendingString:@"_read"]];
            XTIRBlock* joinBB = [self addBlockWithName:[pfx stringByAppendingString:@"_join"]];
            [self emitTerminator:XTIROpCondBranch
                        operands:@[ [XTIROperand useWithValueId:objIsNull.valueId],
                                    [XTIROperand blockWithRef:joinBB],
                                    [XTIROperand blockWithRef:readBB] ]];

            // readBB: obj is non-null. Read obj[0]; a value < 64K is a non-vtable
            // class's class-id (never conforms) → pass null to the helper. The
            // full-width compare must live in IR (xtc pointer compares are 16-bit).
            self.currentBlock = readBB;
            XTIRValue* objPP = [self emitInsnOpcode:XTIROpBitcast
                                             result:ptrPtrV
                                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
            XTIRValue* vtbl = [self emitLoad:objPP pointeeType:ptrVoid];
            // Threshold 0xFFFF: any non-vtable class-id (a U16, < 0x10000) is below
            // it and any real vtable address is above it. 0xFFFF (not 0x10000) so
            // IntToPtr — which narrows to the 16-bit front-end pointer width — keeps
            // it intact instead of truncating 0x10000 to 0. The compare against the
            // vtbl pointer itself is full width (the backend compares real pointers).
            XTIRValue* thrI = [self emitU16Const:0xFFFF];
            XTIRValue* thrP = [self emitInsnOpcode:XTIROpIntToPtr
                                            result:ptrVoid
                                          operands:@[ [XTIROperand useWithValueId:thrI.valueId] ]];
            XTIRValue* isSmall = [self allocateValueOfType:boolTy atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                           result:isSmall
                                                                         operands:@[ [XTIROperand useWithValueId:vtbl.valueId],
                                                                                     [XTIROperand useWithValueId:thrP.valueId] ]
                                                                        predicate:XTIRICmpULT
                                                                           dbgLoc:nil]];
            XTIRValue* nullVtbl = [self emitInsnOpcode:XTIROpIntToPtr
                                                result:ptrVoid
                                              operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];
            XTIRValue* safeVtbl = [self allocateValueOfType:ptrVoid atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                                           result:safeVtbl
                                                                         operands:@[ [XTIROperand useWithValueId:isSmall.valueId],
                                                                                     [XTIROperand useWithValueId:nullVtbl.valueId],
                                                                                     [XTIROperand useWithValueId:vtbl.valueId] ]
                                                                           dbgLoc:nil]];
            XTIRValue* pidV = [self allocateValueOfType:u32t atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                           result:pidV
                                                                         operands:@[ [XTIROperand immIWithType:u32t
                                                                                                         value:(int64_t)xtProtocolId(node.targetProtocolName)] ]
                                                                           dbgLoc:nil]];
            XTIRValue* okRead = [self emitCall:hid
                                      callConv:[XTIRCallConv standard]
                                     argValues:@[ safeVtbl, pidV ]
                                    resultType:boolTy];
            XTIRBlock* readEnd = self.currentBlock;
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBB] ]];

            // joinBB: ok = phi(entry: false [null obj], readEnd: okRead).
            self.currentBlock = joinBB;
            XTIRValueId okVid = [self.currentFunction allocateValueId];
            XTIRValue* ok = [[XTIRValue alloc] initWithValueId:okVid
                                                          type:boolTy
                                                       defSite:[[XTIRDefSite alloc] initWithBlock:joinBB insnIndex:0]];
            [self.currentFunction registerValue:ok];
            NSUInteger ei = [self.currentFunction.blocks indexOfObjectIdenticalTo:entryBB];
            NSUInteger ri = [self.currentFunction.blocks indexOfObjectIdenticalTo:readEnd];
            NSArray<XTIROperand*>* phiOps = (ei < ri)
                                                ? @[ [XTIROperand blockWithRef:entryBB], [XTIROperand useWithValueId:falseC.valueId],
                                                     [XTIROperand blockWithRef:readEnd], [XTIROperand useWithValueId:okRead.valueId] ]
                                                : @[ [XTIROperand blockWithRef:readEnd], [XTIROperand useWithValueId:okRead.valueId],
                                                     [XTIROperand blockWithRef:entryBB], [XTIROperand useWithValueId:falseC.valueId] ];
            [joinBB.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                                 result:ok
                                                               operands:phiOps
                                                                 dbgLoc:nil]];

            if (node.isFailable)
                {
                XTIRValue* sel = [self allocateValueOfType:dstIR atSite:self.currentBlock];
                [self.currentBlock appendInstruction:
                                       [[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                                 result:sel
                                                               operands:@[ [XTIROperand useWithValueId:ok.valueId],
                                                                           [XTIROperand useWithValueId:asP.valueId],
                                                                           [XTIROperand useWithValueId:nullP.valueId] ]
                                                                 dbgLoc:nil]];
                return sel;
                }
            // Plain `(P@)obj`: trap on a miss (matches the class-downcast contract).
            XTIRBlock* cont = [self addBlockWithName:[pfx stringByAppendingString:@"_ok"]];
            XTIRBlock* trap = [self addBlockWithName:[pfx stringByAppendingString:@"_miss"]];
            [self emitTerminator:XTIROpCondBranch
                        operands:@[ [XTIROperand useWithValueId:ok.valueId],
                                    [XTIROperand blockWithRef:cont],
                                    [XTIROperand blockWithRef:trap] ]];
            self.currentBlock = trap;
            [self emitTerminator:XTIROpUnreachable operands:@[]];
            self.currentBlock = cont;
            return asP;
            }
        // Helper absent (non-itable backend reached here unexpectedly): fall
        // through to a plain reinterpret rather than emit a broken call.
        }

    // Class downcast — `(T@) p` / `(T@ ?) p` where T is a class. Sema
    // stamps `targetClassName` on the cast node. Lower it to a runtime
    // subtree-id check (see lowerClassDowncastFrom:): read the instance's
    // stamped class id and test membership in T's subtree, yielding the
    // pointer on a hit and null/trap on a miss.
    if (node.targetClassName)
        {
        XTIRClassInfo* ci = self.classesByName[node.targetClassName];
        if (ci)
            {
            // Source static class (operand's pointee), for the vtable gate.
            XTIRClassInfo* srcCi = nil;
            XTType* opT = node.operand.resolvedType;
            if (opT && [opT isKindOfClass:[XTPointerType class]])
                {
                XTType* pointee = ((XTPointerType*)opT).pointeeType;
                if (pointee)
                    srcCi = self.classesByName[pointee.displayName];
                }
            return [self lowerClassDowncastFrom:src
                                    sourceClass:srcCi
                                    targetClass:ci
                                     resultType:ci.selfPtrType
                                       failable:node.isFailable];
            }
        }

    // Pointer-to-pointer / class-pointer reinterpretation (no width
    // change for 2-byte pointers on 6502, identical encoding on
    // portable targets). Emit a Bitcast — the IR knows the source and
    // destination types both have the same backing width.
    BOOL srcIsPtr = (srcType && srcType.kind == XTTypeKindPointer);
    BOOL dstIsPtr = (dstType && dstType.kind == XTTypeKindPointer);
    if (srcIsPtr && dstIsPtr)
        {
        XTIRValue* bc = [self emitInsnOpcode:XTIROpBitcast
                                      result:dstIR
                                    operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        // Upcast of an owned temp (`(P@)new C()`): ownership follows the cast so
        // the scope-exit sweep releases the LIVE value, not the pre-cast temp.
        [self retargetOwnedTempFrom:src to:bc];
        if (!self.bitcastSource)
            self.bitcastSource = [NSMutableDictionary dictionary];
        self.bitcastSource[@(bc.valueId)] = src;
        return bc;
        }
    // IntToPtr / PtrToInt cover the integer ↔ pointer conversions.
    if (!srcIsPtr && dstIsPtr)
        {
        return [self emitInsnOpcode:XTIROpIntToPtr
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }
    if (srcIsPtr && !dstIsPtr)
        {
        return [self emitInsnOpcode:XTIROpPtrToInt
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }

    // Float casts — int↔float and float↔float. The IR names the
    // action (SIToFp / FpToSI / FpExt / FpTrunc); each backend
    // renders it in its own format. Decide off the actual IR types.
    BOOL srcIsFloat = src.type && XTIRTypeKindIsFloating(src.type.kind);
    BOOL dstIsFloat = XTIRTypeKindIsFloating(dstIR.kind);
    if (srcIsFloat || dstIsFloat)
        {
        if (srcIsFloat && dstIsFloat)
            {
            if (srcType.byteWidth == dstType.byteWidth)
                return src;
            XTIROpcode fop = (dstType.byteWidth > srcType.byteWidth)
                                 ? XTIROpFpExt
                                 : XTIROpFpTrunc;
            return [self emitInsnOpcode:fop
                                 result:dstIR
                               operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
            }
        XTIROpcode fop;
        if (dstIsFloat)
            {
            fop = srcType.isSigned ? XTIROpSIToFp : XTIROpUIToFp;
            }
        else
            {
            fop = dstType.isSigned ? XTIROpFpToSI : XTIROpFpToUI;
            }
        return [self emitInsnOpcode:fop
                             result:dstIR
                           operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
        }

    // Width/signedness come from the ACTUAL IR value, not the AST operand
    // type: a comparison's AST resolvedType is its OPERAND type (u32 for
    // `e > f`) while the value is a 1-byte unsigned Bool — trusting the AST
    // made `(i32)(u32 > u32)` a Bitcast (4==4), splicing garbage high bytes.
    BOOL srcIsBool = src.type && src.type.kind == XTIRTypeKindBool;
    NSUInteger srcW = srcIsBool ? 1 : srcType.byteWidth;
    BOOL srcSigned = srcIsBool ? NO : srcType.isSigned;
    // No-op casts (same width and signedness, or operand already
    // matches dst kind).
    if (!srcIsBool && srcW == dstType.byteWidth && srcSigned == dstType.isSigned)
        {
        return src;
        }
    XTIROpcode op;
    if (dstType.byteWidth > srcW)
        {
        op = srcSigned ? XTIROpSExt : XTIROpZExt;
        }
    else if (dstType.byteWidth < srcW)
        {
        op = XTIROpTrunc;
        }
    else
        {
        // Same width, different signedness — pure reinterpretation.
        // The IR has no opcode for this (the bits are identical); we
        // just return the source value with its new declared type.
        // To keep value-type integrity, emit a Bitcast.
        op = XTIROpBitcast;
        }
    return [self emitInsnOpcode:op
                         result:dstIR
                       operands:@[ [XTIROperand useWithValueId:src.valueId] ]];
    }

#pragma mark - Class-flavoured expressions

// Bare-ivar-shorthand store: `x = rhs` inside a method body where `x`
// names an ivar. Computes FieldAddr(self, slot), runs the same ARC
// release-old / retain-new dance as member-LHS assignment, stores.
- (nullable XTIRValue*)lowerIvarStoreNamed:(NSString*)ivarName
                                       rhs:(XTASTNode*)rhsNode
                                  location:(XTSourceLocation*)loc
    {
    NSNumber* slot = nil;
    XTType* ivarAST = nil;
    for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
        {
        slot = ci.ivarFieldIndex[ivarName];
        if (slot)
            {
            ivarAST = ci.ivarASTType[ivarName];
            break;
            }
        }
    if (!slot || !ivarAST)
        {
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: ivar '%@' not found", ivarName]];
        return nil;
        }

    XTIRValue* rhsVal = [self lowerExpression:rhsNode];
    if (!rhsVal)
        return nil;
    rhsVal = [self coerceValue:rhsVal
                      fromType:rhsNode.resolvedType
                        toType:ivarAST
                      location:loc];

    XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:loc];
    if (!fieldIRType)
        return nil;
    XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
    XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                             fieldIndex:slot.unsignedIntegerValue
                             resultType:fieldPtrType];

    if ([self astTypeIsClassPointer:ivarAST])
        {
        XTIRValue* oldVal = [self emitLoad:fa pointeeType:fieldIRType];
        if ([self arcRhsIsBorrowed:rhsNode])
            {
            if ([self astTypeIsAnyClassPointer:rhsNode.resolvedType])
                [self emitRetain:rhsVal];
            }
        else
            {
            [self consumeOwnedTemp:rhsVal]; // +1 RHS adopted by the ivar (#123)
            }
        [self emitRelease:oldVal];
        }

    [self emitStore:fa value:rhsVal];
    // Weak class-pointer ivar (`weak:T@ wf;`) assigned by BARE IDENTIFIER
    // (`wf = a` inside a method). This routes here, not through
    // lowerMemberAssign, so the weak-slot registration AND the +1 balance were
    // both missing: `wf = new Item()` linked nothing and released nothing — the
    // slot never auto-zeroed and the +1 leaked (bug 170, Leak A). Mirror the
    // member-access path exactly: unregister a prior entry, register the new
    // value, then release a +1 RHS the slot doesn't own.
    if ([self astTypeIsWeakClassPointer:ivarAST])
        {
        [self emitWeakUnregisterSlot:fa];
        [self emitWeakRegisterSlot:fa obj:rhsVal];
        if (![self arcRhsIsBorrowed:rhsNode])
            [self emitRelease:rhsVal];
        }
    // Weak bound method (`weak:action_t^ action;`). This is the path a bare
    // `action = a` inside a method takes — an IDENTIFIER assign, not a member
    // access, so hooking lowerMemberAssign alone missed it entirely and the
    // registration was silently never emitted.
    if ([self astTypeIsWeakBound:ivarAST])
        {
        [self emitWeakBoundRegisterAt:fa value:rhsVal boundType:ivarAST rhsNode:rhsNode];
        }
    return rhsVal;
    }

// Compute the IR address of an addressable struct lvalue. Used by
// both struct member-access (read/write) and `&obj.field` lowering.
// Supported shapes:
//   - Identifier — the local must be pinned; emit AddrOf %pinned.
//   - MemberAccess(base, field) where the surrounding type is a
//     struct — recurse on base for its address (or use the pointer
//     directly for arrow form), then FieldAddr.
- (nullable XTIRValue*)addressOfStructLValue:(XTASTNode*)expr
    {
    if (!expr)
        return nil;
    if (expr.nodeKind == XTASTNodeKindIdentifier)
        {
        XTIdentifierNode* idn = (XTIdentifierNode*)expr;
        XTIRPinnedLocal* pl = self.pinnedLocals[idn.identName];
        if (pl)
            {
            // Weak local: payload sits past the hidden link words. See pinnedAddr:.
            return [self pinnedAddr:pl name:idn.identName outType:NULL];
            }
        NSNumber* gid = self.globalsByName[idn.identName];
        if (gid)
            {
            XTIRSymbol* sym = [self.module symbolForId:gid.unsignedIntegerValue];
            if (!sym)
                {
                [self softFailLoweringAt:expr.location
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: global '%@' lost its symbol", idn.identName]];
                return nil;
                }
            XTIRType* ptrTy = [XTIRType ptrToType:sym.globalType window:XTIRWindowUnbanked];
            return [self emitInsnOpcode:XTIROpAddrOf
                                 result:ptrTy
                               operands:@[ [XTIROperand symWithSymbolId:gid.unsignedIntegerValue] ]];
            }
        // Struct-typed ivar accessed bare inside a method (`at.x` ==
        // `self.at.x`): resolve `at` to FieldAddr(self, ivarSlot) — the
        // address of the struct ivar within the instance — and let the
        // enclosing FieldAddr index into its field. (lowerIdentifier:
        // does the same FieldAddr for scalar ivar *reads*; here we want
        // the address, not a Load.)
        if (self.currentClassInfo && self.currentSelf)
            {
            NSNumber* slot = nil;
            XTType* ivarAST = nil;
            for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
                {
                slot = ci.ivarFieldIndex[idn.identName];
                if (slot)
                    {
                    ivarAST = ci.ivarASTType[idn.identName];
                    break;
                    }
                }
            if (slot && ivarAST)
                {
                XTIRType* ivarIRType = [self irTypeForASTType:ivarAST at:expr.location];
                if (!ivarIRType)
                    return nil;
                XTIRType* ivarPtrType = [XTIRType ptrToType:ivarIRType window:XTIRWindowUnbanked];
                return [self emitFieldAddr:self.currentSelf
                                fieldIndex:slot.unsignedIntegerValue
                                resultType:ivarPtrType];
                }
            }
        [self softFailLoweringAt:expr.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: struct '%@' is neither a pinned local, global, nor ivar",
                                               idn.identName]];
        return nil;
        }
    if (expr.nodeKind == XTASTNodeKindMemberAccess)
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)expr;
        XTType* baseT = m.base.resolvedType;
        XTType* pointee = baseT;
        if (baseT && [baseT isKindOfClass:[XTPointerType class]])
            {
            pointee = ((XTPointerType*)baseT).pointeeType;
            }
        // Struct ivar of a class instance — e.g. `b.inner` where b is a
        // class pointer and `inner` is a `struct Node` ivar. The base is
        // the class pointer itself (load it, no recursion); FieldAddr at
        // the ivar slot yields the embedded struct's address. This lets a
        // nested `b.inner.payload` chain (struct field inside a class
        // ivar) resolve, mirroring decayArrayBaseToPtr:'s class branch.
        if (pointee && pointee.kind == XTTypeKindClass)
            {
            XTIRClassInfo* ci = self.classesByName[pointee.displayName];
            if (!ci)
                {
                [self softFailLoweringAt:expr.location
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: unknown class '%@' for struct-ivar address", pointee.displayName]];
                return nil;
                }
            NSNumber* slot = nil;
            XTType* ivarAST = nil;
            for (XTIRClassInfo* ic = ci; ic != nil; ic = ic.parent)
                {
                slot = ic.ivarFieldIndex[m.memberName];
                if (slot)
                    {
                    ivarAST = ic.ivarASTType[m.memberName];
                    break;
                    }
                }
            if (!slot || !ivarAST)
                {
                [self softFailLoweringAt:expr.location
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: class '%@' has no ivar '%@'",
                                                       pointee.displayName, m.memberName]];
                return nil;
                }
            XTIRValue* basePtr = [self lowerExpression:m.base];
            if (!basePtr)
                return nil;
            XTIRType* ivarIRType = [self irTypeForASTType:ivarAST at:expr.location];
            if (!ivarIRType)
                return nil;
            XTIRType* ivarPtrType = [XTIRType ptrToType:ivarIRType window:XTIRWindowUnbanked];
            return [self emitFieldAddr:basePtr
                            fieldIndex:slot.unsignedIntegerValue
                            resultType:ivarPtrType];
            }
        if (!pointee || pointee.kind != XTTypeKindStruct || ![pointee isKindOfClass:[XTStructType class]])
            {
            [self softFailLoweringAt:expr.location
                         withMessage:@"lowering: struct field-address needs a struct-typed base"];
            return nil;
            }
        // Arrow form when written `->` OR when the base is already a pointer to
        // the struct (`s.w` where `s` is `gfx_surface@`): the base VALUE is the
        // struct's address. Only a struct-by-value base needs addressOfStructLValue.
        BOOL baseIsPointer = (baseT && [baseT isKindOfClass:[XTPointerType class]]);
        XTIRValue* baseAddr = nil;
        if (m.isArrow || baseIsPointer)
            {
            baseAddr = [self lowerExpression:m.base];
            }
        else
            {
            baseAddr = [self addressOfStructLValue:m.base];
            }
        if (!baseAddr)
            return nil;

        NSUInteger fieldIndex = 0;
        XTType* fieldAST = nil;
        if (![self structType:(XTStructType*)pointee
                   fieldNamed:m.memberName
                        index:&fieldIndex
                      astType:&fieldAST])
            {
            [self softFailLoweringAt:expr.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: struct '%@' has no field '%@'",
                                                   pointee.displayName, m.memberName]];
            return nil;
            }
        XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:expr.location];
        if (!fieldIRType)
            return nil;
        XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
        return [self emitFieldAddr:baseAddr
                        fieldIndex:fieldIndex
                        resultType:fieldPtrType];
        }
    // Subscript expression `arr[i]` where the element type is a struct:
    // delegate to emitSubscriptAddress: which handles both array-decay
    // and pointer bases.
    if (expr.nodeKind == XTASTNodeKindSubscriptExpr)
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)expr;
        return [self emitSubscriptAddress:sub.base
                                    index:sub.index
                                 location:sub.location];
        }
    // Dereference expression `(@p)` used as the base of a dot-form
    // member access `(@p).field` — treat it as arrow access: lower the
    // inner pointer expression to get the struct's address directly.
    if (expr.nodeKind == XTASTNodeKindUnaryExpr)
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)expr;
        if (u.op == XTUnaryOpDeref)
            {
            return [self lowerExpression:u.operand];
            }
        }
    [self softFailLoweringAt:expr.location
                 withMessage:@"lowering: struct address not derivable from this lvalue"];
    return nil;
    }

// Emit a property-accessor method call: resolve `<className>$<mangled>`
// (walking parents for an inherited accessor), derive the call conv from
// the symbol's attributes, and emitCall with `self` prepended. Shared by
// the getter (member read) and setter (member store) rewrites.
- (nullable XTIRValue*)emitAccessorCallTo:(XTMethodDeclNode*)method
                                className:(NSString*)className
                                     self:(XTIRValue*)selfVal
                                     args:(NSArray<XTIRValue*>*)argVals
                               resultType:(nullable XTIRType*)resIR
                                 location:(nullable XTSourceLocation*)loc
    {
    NSString* mangled = method.mangledName ?: method.methodName;
    NSString* symName = [NSString stringWithFormat:@"%@$%@", className, mangled];
    XTIRSymbol* sym = [self.module symbolForName:symName];
    if (!sym)
        {
        for (XTIRClassInfo* ci = self.classesByName[className].parent; ci != nil; ci = ci.parent)
            {
            sym = [self.module symbolForName:[NSString stringWithFormat:@"%@$%@", ci.className, mangled]];
            if (sym)
                break;
            }
        }
    if (!sym)
        {
        [self softFailLoweringAt:loc
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: property accessor '%@.%@' not found", className, method.methodName]];
        return nil;
        }
    XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];
    XTIRCallConv* conv = sym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                         : sym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                               : [XTIRCallConv standard];
    NSMutableArray<XTIRValue*>* callArgs = [NSMutableArray arrayWithObject:selfVal];
    [callArgs addObjectsFromArray:argVals];
    return [self emitCall:sid callConv:conv argValues:callArgs resultType:resIR];
    }

- (nullable XTIRValue*)lowerMemberAccess:(XTMemberAccessNode*)node
    {
    // Property-getter rewrite: `obj.prop` where sema resolved a zero-arg
    // getter method routes through a method call instead of an ivar load.
    if ([node.resolvedGetterMethod isKindOfClass:[XTMethodDeclNode class]] && node.resolvedGetterClass)
        {
        XTIRValue* selfVal = [self lowerExpression:node.base];
        if (!selfVal)
            return nil;
        XTIRType* resIR = node.resolvedType
                              ? [self irTypeForASTType:node.resolvedType at:node.location]
                              : nil;
        return [self emitAccessorCallTo:(XTMethodDeclNode*)node.resolvedGetterMethod
                              className:node.resolvedGetterClass
                                   self:selfVal
                                   args:@[]
                             resultType:resIR
                               location:node.location];
        }

    XTASTNode* base = node.base;
    XTType* baseType = base.resolvedType;
    XTType* pointeeAST = baseType;
    if (baseType && [baseType isKindOfClass:[XTPointerType class]])
        {
        pointeeAST = ((XTPointerType*)baseType).pointeeType;
        }
    // Struct-typed base — dot or arrow. Compute the field address
    // (recursing for nested member access) and emit a Load.
    if (pointeeAST && pointeeAST.kind == XTTypeKindStruct && [pointeeAST isKindOfClass:[XTStructType class]])
        {
        XTStructType* st = (XTStructType*)pointeeAST;
        NSUInteger fieldIndex = 0;
        XTType* fieldAST = nil;
        if (![self structType:st
                   fieldNamed:node.memberName
                        index:&fieldIndex
                      astType:&fieldAST])
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: struct '%@' has no field '%@'",
                                                   pointeeAST.displayName, node.memberName]];
            return nil;
            }
        // Struct-rvalue base — `makePoint(…).x`. The call returns an
        // aggregate IR value; pull the field out with AggExtract, no
        // address-of detour (a struct rvalue has no addressable lvalue,
        // which is what addressOfStructLValue: would otherwise reject).
        if (!node.isArrow && (base.nodeKind == XTASTNodeKindCallExpr || base.nodeKind == XTASTNodeKindMethodCallExpr))
            {
            XTIRValue* aggVal = [self lowerExpression:base];
            if (!aggVal)
                return nil;
            XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:node.location];
            if (!fieldIRType)
                return nil;
            XTIRValue* fieldVal = [self allocateValueOfType:fieldIRType atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc]
                                                     initWithOpcode:XTIROpAggExtract
                                                             result:fieldVal
                                                           operands:@[ [XTIROperand useWithValueId:aggVal.valueId],
                                                                       [XTIROperand immIWithType:[XTIRType u16Type]
                                                                                           value:(int64_t)fieldIndex] ]
                                                             dbgLoc:nil]];
            return fieldVal;
            }
        // Arrow form when `->` OR the base is already a pointer to the struct
        // (`s.w` where `s` is `gfx_surface@`): the base value is the address.
        BOOL baseIsPointer = (baseType && [baseType isKindOfClass:[XTPointerType class]]);
        XTIRValue* baseAddr = nil;
        if (node.isArrow || baseIsPointer)
            {
            baseAddr = [self lowerExpression:base];
            }
        else
            {
            baseAddr = [self addressOfStructLValue:base];
            }
        if (!baseAddr)
            return nil;
        XTIRType* fieldIRType = [self irTypeForASTType:fieldAST at:node.location];
        if (!fieldIRType)
            return nil;
        XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
        // An ARRAY field DECAYS to a pointer-to-element (C array decay), exactly
        // as a bare local array does — it must NOT Load the whole aggregate.
        // `len(s.name)` passes &s.name[0]; loading the 20-byte array as a value
        // and handing that to a `u8*` parameter dereferenced the array's own
        // bytes as an address and segfaulted (bug 182). The field's address IS
        // its element 0, so the same FieldAddr typed as Ptr(element) is it.
        if (fieldAST && fieldAST.kind == XTTypeKindArray && [fieldAST isKindOfClass:[XTArrayType class]])
            {
            XTType* elemAst = ((XTArrayType*)fieldAST).elementType;
            XTIRType* elemIR = elemAst ? [self irTypeForASTType:elemAst at:node.location] : nil;
            if (elemIR)
                {
                XTIRType* elemPtrTy = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
                return [self emitFieldAddr:baseAddr fieldIndex:fieldIndex resultType:elemPtrTy];
                }
            }
        XTIRValue* fa = [self emitFieldAddr:baseAddr
                                 fieldIndex:fieldIndex
                                 resultType:fieldPtrType];
        return [self emitLoad:fa pointeeType:fieldIRType];
        }
    // Fixed-size array `.length` — a compile-time constant equal to the
    // declared element count.
    if (pointeeAST && pointeeAST.kind == XTTypeKindArray && [pointeeAST isKindOfClass:[XTArrayType class]] && [node.memberName isEqualToString:@"length"])
        {
        NSUInteger n = ((XTArrayType*)pointeeAST).elementCount;
        XTIRType* cty = [self countIRType];
        XTIRValue* c = [self allocateValueOfType:cty atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:c
                                                                     operands:@[ [XTIROperand immIWithType:cty value:(int64_t)n] ]
                                                                       dbgLoc:nil]];
        return c;
        }
    // Heap-pointer `.length` — `T@ p = new T[N];` recorded N at decl
    // time. The runtime header isn't read; this is a static value
    // associated with the binding. A local that's been reassigned
    // since drops out of the map and falls through to the soft-fail.
    if ([node.memberName isEqualToString:@"length"] && [node.base isKindOfClass:[XTIdentifierNode class]])
        {
        NSString* ln = ((XTIdentifierNode*)node.base).identName;
        NSNumber* nN = self.heapArrayLengthByLocal[ln];
        if (nN)
            {
            XTIRType* cty = [self countIRType];
            XTIRValue* c = [self allocateValueOfType:cty atSite:self.currentBlock];
            [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                           result:c
                                                                         operands:@[ [XTIROperand immIWithType:cty
                                                                                                         value:nN.longLongValue] ]
                                                                           dbgLoc:nil]];
            return c;
            }
        }
    // `.length` on a pointer whose count the compiler did NOT record — a
    // runtime-sized `new T[n]`, a reassigned local, a pointer from another
    // function. The allocation header carries the element count on every
    // target whose runtime writes one, so this is now a REAL header read:
    // a call to the per-runtime `_xtc_count` helper (each runtime owns its
    // own header layout — one truth per role). The xt6502 is the exception:
    // its primitive-array allocator hands the request straight to the
    // free-list heap with no count cookie, so it keeps the honest
    // diagnostic. Discriminated by heap-pointer width — the 6502 family is
    // 2/3 bytes, every counted-header target is >= 4. private:docs/bugs/045.
    if ([node.memberName isEqualToString:@"length"] && node.base.resolvedType && [node.base.resolvedType isKindOfClass:[XTPointerType class]])
        {
        if ([XTPointerType heapPointerWidth] >= 4)
            {
            XTIRValue* bv = [self lowerExpression:node.base];
            if (!bv)
                return nil;
            XTIRSymbolId sid = [self runtimeHelperSymbolNamed:@"_xtc_count"];
            return [self emitCall:sid
                         callConv:[XTIRCallConv standard]
                        argValues:@[ bv ]
                       resultType:[self countIRType]];
            }
        [self softFailLoweringAt:node.location
                     withMessage:
                         @"lowering: on this target '.length' is resolved at COMPILE time "
                         @"from a `new T[N]` with a constant N assigned to a named local "
                         @"in this function — the xt6502 heap stores no element count for "
                         @"a primitive array, so a runtime-sized allocation has no length "
                         @"to give here. Keep the count in a variable of your own. See "
                         @"private:docs/bugs/045."];
        return nil;
        }
    if (!pointeeAST || pointeeAST.kind != XTTypeKindClass)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: member access on non-class base"];
        return nil;
        }
    XTIRClassInfo* baseCi = self.classesByName[pointeeAST.displayName];
    if (!baseCi)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unknown class '%@' for member access", pointeeAST.displayName]];
        return nil;
        }

    NSNumber* slot = nil;
    XTType* ivarAST = nil;
    for (XTIRClassInfo* ci = baseCi; ci != nil; ci = ci.parent)
        {
        slot = ci.ivarFieldIndex[node.memberName];
        if (slot)
            {
            ivarAST = ci.ivarASTType[node.memberName];
            break;
            }
        }
    if (!slot || !ivarAST)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: class '%@' has no ivar '%@'",
                                               pointeeAST.displayName, node.memberName]];
        return nil;
        }

    XTIRValue* basePtr = [self selfPointerForClassBase:base];
    if (!basePtr)
        return nil;
    XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:node.location];
    if (!fieldIRType)
        return nil;
    XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType window:XTIRWindowUnbanked];
    XTIRValue* fa = [self emitFieldAddr:basePtr
                             fieldIndex:slot.unsignedIntegerValue
                             resultType:fieldPtrType];
    return [self emitLoad:fa pointeeType:fieldIRType];
    }

/****************************************************************************\
|* Re-type a method-call result that a typed collection substituted.
|*
|* The Call carries the type the CALLEE returns (`Object*`); the call SITE was
|* resolved to the collection's element type. Bridge them with a Bitcast — the
|* same instruction an explicit `(String*)a.get(i)` lowers to, minus the RTTI
|* check, because a typed collection cannot hold anything else by construction.
|* @param v     The value the Call produced.
|* @param node  The method-call node, carrying both types.
|* @return  `v` re-typed, or `v` unchanged for an ordinary call.
\****************************************************************************/
- (nullable XTIRValue*)retypeErasedResult:(nullable XTIRValue*)v
                                  forCall:(XTMethodCallExprNode*)node
    {
    if (!v || !node.erasedReturnType)
        return v;
    XTIRType* want = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!want || [want isEqual:v.type])
        return v;
    return [self emitInsnOpcode:XTIROpBitcast
                         result:want
                       operands:@[ [XTIROperand useWithValueId:v.valueId] ]];
    }

- (nullable XTIRValue*)lowerMethodCallExpr:(XTMethodCallExprNode*)node
    {
    // Sema found the "method" was a FIELD holding something callable and
    // rewrote this into an indirect call. Everything below is method
    // dispatch, none of which applies. private:docs/bugs/074.
    if (node.indirectRewrite)
        return [self lowerExpression:node.indirectRewrite];
    // Resolve receiver and class info.
    XTASTNode* receiver = node.receiver;
    XTType* baseType = receiver.resolvedType;

    // PR5: `super.method(args)` — the receiver is the keyword `super`
    // (an identifier with no resolvedType from sema). The sema has already
    // resolved the target class and mangled name, so we dispatch directly
    // to the parent class implementation, passing `self` as receiver.
    BOOL isSuperCall =
        [receiver isKindOfClass:[XTIdentifierNode class]] &&
        [((XTIdentifierNode*)receiver).identName isEqualToString:@"super"];

    if (isSuperCall)
        {
        if (!self.currentSelf)
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: 'super' outside of class method"];
            return nil;
            }
        NSString* ownerName = node.resolvedClassName;
        if (!ownerName)
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: super call without resolved class name"];
            return nil;
            }
        XTIRClassInfo* recvCi = self.classesByName[ownerName];
        if (!recvCi)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: unknown class '%@' for super call", ownerName]];
            return nil;
            }

        // Lower argument expressions.
        NSMutableArray<XTIRValue*>* args = [NSMutableArray array];
        for (XTASTNode* a in node.arguments)
            {
            XTIRValue* av = [self lowerExpression:a];
            if (!av)
                return nil;
            [args addObject:av];
            }

        XTIRType* resultIR = nil;
        XTType* callResultAST = node.erasedReturnType ?: node.resolvedType;
        if (callResultAST && !callResultAST.isVoid)
            {
            resultIR = [self irTypeForASTType:callResultAST at:node.location];
            if (!resultIR)
                return nil;
            }

        NSString* mangled = node.resolvedMangledName ?: node.methodName;
        NSString* symName = [NSString stringWithFormat:@"%@$%@", ownerName, mangled];

        XTIRSymbol* sym = [self.module symbolForName:symName];
        if (!sym)
            {
            [self softFailLoweringAt:node.location
                         withMessage:[NSString stringWithFormat:
                                                   @"lowering: super method '%@' not found in '%@'",
                                                   node.methodName, ownerName]];
            return nil;
            }
        XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];

        // Coerce each fixed arg to the callee's matching param type.
        if (sym.function)
            {
            NSUInteger nParam = sym.function.paramTypes.count; // self + fixed + Mem
            for (NSUInteger i = 0; i < args.count && i < node.arguments.count; i++)
                {
                NSUInteger pIdx = i + 1; // +1 for self
                if (pIdx + 1 >= nParam)
                    break;
                XTIRType* dstIR = sym.function.paramTypes[pIdx];
                XTType* srcAST = [node.arguments[i] resolvedType];
                if (!srcAST || dstIR.kind == XTIRTypeKindVoid || dstIR.kind == XTIRTypeKindPtr)
                    continue;
                // NEVER integer-extend an aggregate. A `^` parameter is an Agg, and this
                // loop would otherwise emit `ZExt %agg` from the ARGUMENT's pointer width.
                // An fn-pointer arg here is a `@`->`^` widening; any other aggregate is
                // already the value the callee wants.
                if (dstIR.kind == XTIRTypeKindAgg)
                    {
                    [self widenBoundArgAt:i in:args ofASTType:srcAST toAgg:dstIR];
                    continue;
                    }
                NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
                BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                if (srcW == dstW && srcSgn == dstSgn)
                    continue;
                XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                                : dstW < srcW ? XTIROpTrunc
                                              : XTIROpBitcast;
                XTIRValue* cv = [self emitInsnOpcode:op
                                              result:dstIR
                                            operands:@[ [XTIROperand useWithValueId:((XTIRValue*)args[i]).valueId] ]];
                if (cv)
                    args[i] = cv;
                }
            }

        // Variadic callee: xtc-authored → pack past fixed params; C-ABI import
        // (printf) → C default-promote the tail and pass it AAPCS (no pack).
        NSArray<XTIRValue*>* passArgs = args;
        if (sym.attributes[@"variadic"].boolValue && sym.function)
            {
            NSInteger fc = (NSInteger)sym.function.paramTypes.count - 2; // drop self + Mem
            NSUInteger fcu = fc > 0 ? (NSUInteger)fc : 0;
            // C-ABI import (printf) OR a native-AAPCS-va_list target (arm9, where
            // every variadic callee reads AAPCS regs/stack, not __xtc_va_buf) →
            // promote + pass natively; otherwise pack the buffer.
            passArgs = (sym.attributes[@"cabi"].boolValue || self.nativeVarargs)
                           ? [self cVarargPromote:args fixedCount:fcu]
                           : [self packVarargsFrom:args fixedCount:fcu];
            }

        NSMutableArray<XTIRValue*>* callArgs = [NSMutableArray array];
        [callArgs addObject:self.currentSelf]; // instance self
        [callArgs addObjectsFromArray:passArgs];
        return [self emitCall:sid
                     callConv:[XTIRCallConv standard]
                    argValues:callArgs
                   resultType:resultIR];
        }

    // A bare class-typed receiver is ambiguous: it's a static call
    // (`Stdio.foo()` — the receiver names the class) UNLESS the receiver
    // names a stack-allocated value instance (`Animal a; a.describe()`),
    // in which case it's a real instance call whose self is the slot
    // address. lowerExpression on the value-instance identifier yields
    // that self-pointer (see lowerIdentifier's valueClassLocals branch).
    BOOL isValueInstance = [self isValueInstanceBase:receiver];

    // Static call: the receiver is the class type itself (`Stdio.foo`),
    // not a pointer-to-instance. There's no `self` to lower or pass —
    // the method body reaches class fields via its `__sdata` self.
    BOOL isStaticCall = (baseType && baseType.kind == XTTypeKindClass && ![baseType isKindOfClass:[XTPointerType class]] && !isValueInstance);
    // …but a class-typed LOCAL VARIABLE is a heap instance receiver
    // (`Counter c = new Counter(); c.set(x)`), whose declared type is a bare
    // class rather than a pointer and which isn't a stack value-instance — so it
    // slips past both guards above and is mis-classified as static. Only a
    // receiver that *names the class itself* is static; an identifier that lives
    // in `self.locals` is a variable. Without this, `self` is never passed: a
    // no-arg method limps along on whatever happens to be in x0, but a method
    // WITH arguments takes its first argument in self's register and dereferences
    // it as the object pointer — a wild store / SIGSEGV.
    if (isStaticCall && [receiver isKindOfClass:[XTIdentifierNode class]] && self.locals[((XTIdentifierNode*)receiver).identName] != nil)
        {
        isStaticCall = NO;
        }
    XTType* pointeeAST = baseType;
    if (baseType && [baseType isKindOfClass:[XTPointerType class]])
        {
        pointeeAST = ((XTPointerType*)baseType).pointeeType;
        }
    if (!pointeeAST || pointeeAST.kind != XTTypeKindClass)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: method call on non-class receiver"];
        return nil;
        }
    XTIRClassInfo* recvCi = self.classesByName[pointeeAST.displayName];
    if (!recvCi)
        {
        // Protocol-typed receiver (`Drawable@ d; d.draw()`): there is no
        // concrete class — sema stamped a virtual slot, so dispatch
        // through the receiver object's vtable (task #58). A genuinely
        // unknown class (no slot) still soft-fails below.
        if (!isStaticCall && node.resolvedVirtualSlot != nil)
            {
            XTIRValue* recvVal = [self selfPointerForClassBase:receiver];
            if (!recvVal)
                return nil;
            NSMutableArray<XTIRValue*>* args = [NSMutableArray array];
            for (XTASTNode* a in node.arguments)
                {
                XTIRValue* av = [self lowerExpression:a];
                if (!av)
                    return nil;
                [args addObject:av];
                }
            // Widen each arg to the protocol method's declared param type — the
            // dispatch pushes args at their own IR width, so a narrow literal
            // (`p.ping(5)` into an `i32` param) would otherwise reach the callee
            // one slot short and shift its frame (bug 013). The direct-call and
            // implicit-self paths already coerce; this brings the explicit
            // protocol-receiver path to parity.
            [self coerceArgs:args toProtocolMethodOf:node];
            XTIRType* resultIR = nil;
            XTType* callResultAST = node.erasedReturnType ?: node.resolvedType;
            if (callResultAST && !callResultAST.isVoid)
                {
                resultIR = [self irTypeForASTType:callResultAST at:node.location];
                if (!resultIR)
                    return nil;
                }
            // A protocol receiver dispatches through the ITABLE on multi-module
            // targets: the flat slot number cannot be agreed between two
            // independently built libraries, but a protocol-relative index needs no
            // agreeing.
            if (sItableProtocols && node.resolvedProtocolName.length && node.resolvedProtocolIndex != nil)
                {
                return [self emitProtoDispatch:recvVal
                                      protocol:node.resolvedProtocolName
                                         index:node.resolvedProtocolIndex.unsignedIntegerValue
                                     argValues:args
                                    resultType:resultIR];
                }
            return [self emitVTblDispatch:recvVal
                                     slot:node.resolvedVirtualSlot.unsignedIntegerValue
                                argValues:args
                               resultType:resultIR];
            }
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unknown class '%@' for method call", pointeeAST.displayName]];
        return nil;
        }

    XTIRValue* recvVal = nil;
    if (!isStaticCall)
        {
        recvVal = [self selfPointerForClassBase:receiver];
        if (!recvVal)
            return nil;
        }
    else
        {
        // Run the class's `init` once on its `__sdata` block before the
        // first (and every) static call, guarded by `__sinit_<C>`. The
        // static body uses zeroed `__sdata` otherwise — e.g. Stdio never
        // sets `canPrint`, so `printf` silently no-ops.
        [self emitStaticInitGuardForClass:recvCi];
        }

    // Lower argument expressions.
    NSMutableArray<XTIRValue*>* args = [NSMutableArray array];
    for (XTASTNode* a in node.arguments)
        {
        XTIRValue* av = [self lowerExpression:a];
        if (!av)
            return nil;
        [args addObject:av];
        }

    XTIRType* resultIR = nil;
    XTType* callResultAST = node.erasedReturnType ?: node.resolvedType;
    if (callResultAST && !callResultAST.isVoid)
        {
        resultIR = [self irTypeForASTType:callResultAST at:node.location];
        if (!resultIR)
            return nil;
        }

    // Virtual dispatch — sema stamps `resolvedVirtualSlot` for protocol
    // calls; for inheritance we look up the method's slot in the
    // receiver class's slot table. Direct call when the method has no
    // vtable slot (i.e. non-overridable).
    NSNumber* vslot = node.resolvedVirtualSlot;
    if (!vslot)
        {
        NSNumber* s = recvCi.methodSlot[node.methodName];
        if (s)
            vslot = s;
        }
    // §4.2: a category method on a class from another module has a CHAIN slot
    // instead of a vtable slot — the two spaces are disjoint, and sema gives a
    // method one or the other, never both.
    NSNumber* cslot = recvCi.catSlot[node.methodName];

    NSString* mangled = node.resolvedMangledName ?: node.methodName;
    NSString* ownerName = node.resolvedClassName ?: recvCi.className;
    NSString* symName = [NSString stringWithFormat:@"%@$%@", ownerName, mangled];

    XTIRSymbol* sym = [self.module symbolForName:symName];
    if (!sym)
        {
        // Walk parent classes — the method may be inherited.
        for (XTIRClassInfo* ci = recvCi.parent; ci != nil; ci = ci.parent)
            {
            NSString* parentSym = [NSString stringWithFormat:@"%@$%@",
                                                             ci.className, mangled];
            sym = [self.module symbolForName:parentSym];
            if (sym)
                {
                symName = parentSym;
                break;
                }
            }
        }
    if (!sym)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: method '%@.%@' not found",
                                               recvCi.className, node.methodName]];
        return nil;
        }
    XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];

    // Coerce each fixed arg to the callee's matching param type — the same
    // width/sign adjustment lowerCallExpr applies to free calls. Without it
    // a small integer literal passed to a wider param (e.g.
    // `Number.withI16(10)`, where 10 is typed U8) reaches the callee
    // untouched; the xt6502 backend then pushes only the literal's byte
    // width, leaving the param's high byte(s) stale on the hw stack (the
    // value arrived as -758 = $FD0A). `args` excludes self, so the callee
    // param index is arg index + (instance ? 1 : 0); the trailing Memory
    // token and any variadic tail (packed separately below) are skipped.
    if (sym.function)
        {
        NSUInteger selfOff = isStaticCall ? 0 : 1;
        NSUInteger nParam = sym.function.paramTypes.count; // self? + fixed + Mem
        for (NSUInteger i = 0; i < args.count && i < node.arguments.count; i++)
            {
            NSUInteger pIdx = i + selfOff;
            if (pIdx + 1 >= nParam)
                break; // reached the Memory token / varargs
            XTIRType* dstIR = sym.function.paramTypes[pIdx];
            XTType* srcAST = [node.arguments[i] resolvedType];
            if (!srcAST || dstIR.kind == XTIRTypeKindVoid || dstIR.kind == XTIRTypeKindPtr)
                continue;
            // NEVER integer-extend an aggregate. A `^` parameter is an Agg, and this
            // loop would otherwise emit `ZExt %agg` from the ARGUMENT's pointer width.
            // An fn-pointer arg here is a `@`->`^` widening; any other aggregate is
            // already the value the callee wants.
            if (dstIR.kind == XTIRTypeKindAgg)
                {
                [self widenBoundArgAt:i in:args ofASTType:srcAST toAgg:dstIR];
                continue;
                }
            NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
            BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
            if (srcW == dstW && srcSgn == dstSgn)
                continue;
            XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                            : dstW < srcW ? XTIROpTrunc
                                          : XTIROpBitcast;
            XTIRValue* cv = [self emitInsnOpcode:op
                                          result:dstIR
                                        operands:@[ [XTIROperand useWithValueId:((XTIRValue*)args[i]).valueId] ]];
            if (cv)
                args[i] = cv;
            }
        }

    // Variadic callee (printf, …): pack the user args past the fixed
    // params into `__xtc_va_buf` and pass only the fixed prefix — the
    // callee reads the rest back via va_arg. `args` excludes self, so
    // the fixed-user-param count drops the trailing Memory token and
    // (for an instance call) the leading self.
    NSArray<XTIRValue*>* passArgs = args;
    if (sym.attributes[@"variadic"].boolValue && sym.function)
        {
        NSInteger fc = (NSInteger)sym.function.paramTypes.count - 1; // drop Memory
        if (!isStaticCall)
            fc -= 1; // drop self
        NSUInteger fcu = fc > 0 ? (NSUInteger)fc : 0;
        // `%e` enum-name rewrite — targets xtc-authored variadic callees (which
        // only understand %s); it must NOT touch a C-ABI import (printf), where
        // %e is scientific notation. It runs BEFORE the tail is passed because it
        // substitutes both the format-string arg and the enum-typed value args
        // in-place, independent of how the tail travels (buffer vs AAPCS). On a
        // native-varargs target (arm9) an xtc printf still goes through
        // cVarargPromote, so this can't live in the buffer branch alone.
        //   The format-string slot is the last fixed param: for printf it's arg 0,
        // for printfAt arg 2 (after the x/y positionals). paramTypes.count
        // includes the Memory token and (for instance methods) self, so the last
        // fixed param sits at count - 2 - selfOff. For a static call args mirrors
        // node.arguments 1:1, so that index also indexes args / astArgs.
        if (!sym.attributes[@"cabi"].boolValue)
            {
            NSUInteger fmtArgIdx = sym.function.paramTypes.count >= 2
                                       ? sym.function.paramTypes.count - 2
                                       : 0;
            if (!isStaticCall && fmtArgIdx > 0)
                fmtArgIdx -= 1;
            [self rewriteEnumPercentEInArgs:args
                                    astArgs:node.arguments
                                     fmtIdx:fmtArgIdx];
            }
        if (sym.attributes[@"cabi"].boolValue || self.nativeVarargs)
            {
            // C-ABI import (printf), or a native-AAPCS-va_list target (arm9):
            // C default-promote the tail and pass it per the C ABI so the callee
            // reads it from its register save area (and can forward a real
            // va_list to libc vprintf).
            passArgs = [self cVarargPromote:args fixedCount:fcu];
            }
        else
            {
            passArgs = [self packVarargsFrom:args fixedCount:fcu];
            }
        }
    // Virtual dispatch (task #110): a method with a vtable slot on a
    // vtable-bearing receiver dispatches through the object's vtable so a
    // base-class pointer reaches the dynamic type's override. `super.foo()`
    // already took the direct-call path above, and static calls have no
    // `vslot`. The needsVtable gate keeps non-virtual classes — whose
    // legacy declaration-order `methodSlot` is still populated — on the
    // direct Call, preserving "non-overridden methods stay static" (T7).
    // Arg width/sign coercion above used the statically-resolved `sym`;
    // override signatures match the base, so the param types agree.
    if (cslot && !isStaticCall && recvCi.needsVtable && recvCi.catChainAnchor.length)
        {
        return [self retypeErasedResult:[self emitCatDispatch:recvVal
                                                       anchor:recvCi.catChainAnchor
                                                         slot:cslot.unsignedIntegerValue
                                                    argValues:passArgs
                                                   resultType:resultIR]
                                forCall:node];
        }
    if (vslot && !isStaticCall && recvCi.needsVtable)
        {
        return [self retypeErasedResult:[self emitVTblDispatch:recvVal
                                                          slot:vslot.unsignedIntegerValue
                                                     argValues:passArgs
                                                    resultType:resultIR]
                                forCall:node];
        }

    NSMutableArray<XTIRValue*>* callArgs = [NSMutableArray array];
    if (!isStaticCall)
        [callArgs addObject:recvVal]; // instance self
    [callArgs addObjectsFromArray:passArgs];
    return [self retypeErasedResult:[self emitCall:sid
                                          callConv:[XTIRCallConv standard]
                                         argValues:callArgs
                                        resultType:resultIR]
                            forCall:node];
    }

// The IR type of an element COUNT — `.length` and the `for (v in heapPtr)`
// trip count. It is the width of the allocation header's count field, which
// is NOT the pointer width: arm9 and m68k both have 4-byte pointers but hold
// 4- and 2-byte counts. Hard-wired to u16 once, which truncated every array
// over 65535 elements to `count & 0xFFFF` — and because the same call feeds
// for-in, it silently shortened ITERATION too, not just a printed number.
// Bug 234.
// The AST type matching countIRType. Both exist because a slice bound is
// coerced at the AST level and emitted at the IR level, and the two must name
// the same width.
- (XTType*)countASTType
    {
    NSUInteger w = [XTPointerType heapCountWidth];
    return w >= 8 ? [XTType u64Type] : w >= 4 ? [XTType u32Type] : [XTType u16Type];
    }

- (XTIRType*)countIRType
    {
    NSUInteger w = [XTPointerType heapCountWidth];
    return w >= 8 ? [XTIRType u64Type] : w >= 4 ? [XTIRType u32Type] : [XTIRType u16Type];
    }

- (nullable XTIRValue*)lowerNewExpr:(XTNewExprNode*)node
    {
    // Class allocations route through a per-class runtime helper
    // `_xtc_new_<Class>` that allocates, sets the vtable slot, and
    // invokes the resolved init. The IR-SPEC §14 leaves the precise
    // shape of `new T` to the lowering; this single-call form mirrors
    // the helper convention used elsewhere (the heap allocator already
    // exposes per-class new helpers in support/xt6502/asm/heap/).
    XTIRClassInfo* ci = self.classesByName[node.className];
    if (!ci)
        {
        // Non-class `new` (`new u8[N]`, `new u16`) — route through a
        // generic _xtc_new_<typename> helper. Keeps the lowering
        // honest about the side effect without committing to a
        // specific runtime call shape yet.
        }
    // Constructor arguments (for the class's init — NOT the allocator).
    NSMutableArray<XTIRValue*>* ctorArgs = [NSMutableArray array];
    for (XTASTNode* a in node.arguments)
        {
        XTIRValue* av = [self lowerExpression:a];
        if (!av)
            return nil;
        [ctorArgs addObject:av];
        }
    // Element count (N for `new T[N]`, else 1), widened to u16. A narrower
    // count — e.g. the u8 literal in `new pointer[16]` — would marshal as a
    // single byte, leaving the allocator's count-hi uninitialised.
    XTIRValue* countVal = nil;
    if (node.countExpr)
        {
        countVal = [self lowerExpression:node.countExpr];
        if (!countVal)
            return nil;
        XTType* cntAST = node.countExpr.resolvedType;
        if (cntAST && cntAST.byteWidth < 2)
            {
            countVal = [self coerceValue:countVal
                                fromType:cntAST
                                  toType:[XTType u16Type]
                                location:node.location];
            }
        else if (cntAST)
            {
            // …and NARROWED when it is wider than the target's word. The
            // runtime takes `unsigned long count`, which is 8 bytes on a
            // 64-bit host but 4 on wasm32 — so `new u8[n]` with a u64 `n`
            // handed an i64 to an i32 parameter and the module failed
            // validation ("call[0] expected type i32, found local.get of type
            // i64"). Native never noticed: a u64 count already fits its word.
            // Only narrowing is done here, so every count that already fits
            // lowers exactly as before (bug 38).
            NSUInteger word = [XTPointerType heapPointerWidth];
            XTType* wordTy = word >= 8   ? [XTType u64Type]
                             : word >= 4 ? [XTType u32Type]
                                         : [XTType u16Type];
            if (cntAST.byteWidth > wordTy.byteWidth)
                {
                countVal = [self coerceValue:countVal
                                    fromType:cntAST
                                      toType:wordTy
                                    location:node.location];
                }
            }
        }
    else
        {
        countVal = [self emitU16Const:1];
        }
    // Allocator args. A CLASS allocator takes (count, elemSize): it writes
    // both into the object header so `delete` of an array-of-class iterates
    // dealloc once per element (count steps by elemSize). count=1 for a
    // scalar `new T()` → the delete loop runs once, identical to before.
    // A non-class allocator (`new u8[N]`) takes just the count.
    // B1: a CLASS allocation routes through ONE generic
    // `_xtc_alloc(count, stride, deallocPtr)` rather than a per-class
    // `_xtc_new_<T>`. The dealloc fnptr (or null) is now a runtime argument,
    // so the runtime needs a single allocator instead of one per class — a
    // real code-size win, sharpest on the banked 6502. A PRIMITIVE array
    // (`new u8[N]`) keeps its bounded per-type `_xtc_new_<prim>` helper: those
    // carry the per-backend element width (pointer = 3/4/8 bytes) that the
    // shared lowering can't compute.
    NSArray<XTIRValue*>* allocArgs;
    NSString* helperName;
    if (ci)
        {
        uint32_t stride = ci.instanceLayout ? (uint32_t)ci.instanceLayout.size : 0;
        XTIRValue* strideVal = [self emitU16Const:stride];
        // dealloc pointer: &<Class>$dealloc when one exists (own or synthesised
        // for strong-ivar/inheritance teardown — same test the backends used),
        // else a null pointer. Null via Const#0:U16 → IntToPtr (a direct Const
        // of Ptr type is mis-sized on arm64 — see the cast-failable path).
        XTIRType* dpTy = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
        NSString* deallocName = [NSString stringWithFormat:@"%@$dealloc", node.className];
        XTIRSymbol* deallocSym = [self.module symbolForName:deallocName];
        XTIRValue* deallocPtr;
        if (deallocSym)
            {
            XTIRSymbolId did = [self.module.symbols indexOfObjectIdenticalTo:deallocSym];
            deallocPtr = [self emitInsnOpcode:XTIROpAddrOf
                                       result:dpTy
                                     operands:@[ [XTIROperand symWithSymbolId:did] ]];
            }
        else
            {
            deallocPtr = [self emitInsnOpcode:XTIROpIntToPtr
                                       result:dpTy
                                     operands:@[ [XTIROperand useWithValueId:[self emitU16Const:0].valueId] ]];
            }
        allocArgs = @[ countVal, strideVal, deallocPtr ];
        helperName = @"_xtc_alloc";
        }
    else
        {
        // B2: a NON-class allocation — a struct array or a primitive array —
        // calls the per-type `_xtc_new_<T>` helper the driver synthesises from
        // the generated asm. That helper comes in two shapes, and the caller
        // must match the one it will get:
        //
        //   primitive (`new u8[N]`)   -> _xtc_new_u8(count)
        //       The element width is per-BACKEND (a pointer is 3, 4 or 8 bytes)
        //       so the shared lowering cannot compute it; the stub bakes it in
        //       and takes the count alone.
        //   struct    (`new Point[N]`)-> _xtc_new_Point(count, stride)
        //       A struct's size IS known here — it is the IR layout's, the same
        //       number the class path passes — so the stub takes it as an
        //       argument rather than baking it.
        //
        // Passing only the count to the two-argument form left `stride` as
        // whatever the register happened to hold: on arm9 that reached
        // calloc(1, count*garbage) which failed, and the stub wrote the object
        // header through the resulting NULL (DATA-ABORT, DFAR=0). arm64 survived
        // on luck alone — its second register happened to hold something small.
        // Bug 027. The name test mirrors the stub generator's own primitive set
        // (xtc/main.m) so caller and callee cannot disagree about the shape.
        XTIRValue* structStride = nil;
        if (node.countExpr || node.resolvedType)
            {
            XTIRType* rt = node.resolvedType
                               ? [self irTypeForASTType:node.resolvedType at:node.location]
                               : nil;
            XTIRType* pointee = (rt && rt.kind == XTIRTypeKindPtr) ? rt.pointeeType : nil;
            if (pointee && pointee.kind == XTIRTypeKindAgg && pointee.layout && !XTIRIsPrimitiveElemName(node.className))
                structStride = [self emitU16Const:(uint32_t)pointee.layout.size];
            }
        if (structStride)
            {
            allocArgs = @[ countVal, structStride ];
            }
        else
            {
            allocArgs = node.countExpr ? @[ countVal ] : @[];
            }
        helperName = [NSString stringWithFormat:@"_xtc_new_%@", node.className];
        }
    NSMutableArray<XTIRValue*>* args = [allocArgs mutableCopy];
    XTIRSymbolId sid = [self runtimeHelperSymbolNamed:helperName];

    XTIRType* resultIR = nil;
    if (ci)
        {
        resultIR = ci.selfPtrType;
        }
    else if (node.resolvedType)
        {
        resultIR = [self irTypeForASTType:node.resolvedType at:node.location];
        if (!resultIR)
            return nil;
        }
    else
        {
        resultIR = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
        }

    // Class allocation: the allocator only allocates (+ refcount /
    // vtable) — it does NOT run the constructor. Emit the alloc with
    // no args, then a separate Call to the resolved `init` so the
    // instance's ivars are actually set up. Without this, methods that
    // read an ivar (e.g. a backing-store pointer) dereference garbage.
    if (ci && node.resolvedInitMangledName.length)
        {
        // The allocator gets (count, elemSize); init gets the ctor args.
        XTIRValue* instance = [self emitCall:sid
                                    callConv:[XTIRCallConv standard]
                                   argValues:args
                                  resultType:resultIR];
        if (!instance)
            return nil;
        // Set the vtable pointer before init runs (init may dispatch).
        [self emitVtableInitFor:instance class:ci];
        // Zero the strong-pointer ivars before init: the free-list heap
        // hands back a REUSED block without clearing it, so a strong ivar
        // can hold a dangling pointer from the slot's previous tenant. The
        // first `inst.field = …` (in init or after) runs an ARC release-old
        // on that field, which must read null — otherwise it frees an
        // unrelated live object (private:docs/bugs/008). Stack instances already do
        // this (emitZeroInitIvarsFor:); the heap path used to rely on the
        // allocator zeroing, which the 6502 free-list allocator does not.
        if ([self classHasStrongPointerIvar:ci])
            [self emitZeroInitIvarsFor:instance class:ci];
        // Stamp the RTTI class id so a later downcast can read the type.
        [self emitClassIdStampFor:instance class:ci];

        // Resolve the init symbol, walking parents for an inherited
        // init (mirrors lowerMethodCallExpr:).
        NSString* initSym = [NSString stringWithFormat:@"%@$%@",
                                                       ci.className, node.resolvedInitMangledName];
        XTIRSymbol* isym = [self.module symbolForName:initSym];
        if (!isym)
            {
            for (XTIRClassInfo* p = ci.parent; p != nil; p = p.parent)
                {
                NSString* ps = [NSString stringWithFormat:@"%@$%@",
                                                          p.className, node.resolvedInitMangledName];
                isym = [self.module symbolForName:ps];
                if (isym)
                    {
                    initSym = ps;
                    break;
                    }
                }
            }
        if (isym)
            {
            // Coerce each constructor arg to the matching init param type
            // (mirror lowerMethodCallExpr / phase-083): a small literal
            // passed to a wider init param — e.g. the `-50` (typed i8) in
            // `new P3(50000, 99, -50)` reaching an `i16` param — would
            // otherwise arrive at its narrow width, leaving the high
            // byte(s) stale on the xt6502 hw stack. init's params are
            // [self, fixed…, Mem], so arg i maps to paramTypes[i+1].
            if (isym.function)
                {
                NSUInteger nParam = isym.function.paramTypes.count;
                for (NSUInteger i = 0; i < ctorArgs.count && i < node.arguments.count; i++)
                    {
                    NSUInteger pIdx = i + 1; // skip self
                    if (pIdx + 1 >= nParam)
                        break; // reached the Memory token
                    XTIRType* dstIR = isym.function.paramTypes[pIdx];
                    XTType* srcAST = [node.arguments[i] resolvedType];
                    if (!srcAST || dstIR.kind == XTIRTypeKindVoid || dstIR.kind == XTIRTypeKindPtr)
                        continue;
                    // NEVER integer-extend an aggregate. A `^` parameter is an Agg, and this
                    // loop would otherwise emit `ZExt %agg` from the ARGUMENT's pointer width.
                    // An fn-pointer arg here is a `@`->`^` widening; any other aggregate is
                    // already the value the callee wants.
                    if (dstIR.kind == XTIRTypeKindAgg)
                        {
                        [self widenBoundArgAt:i in:ctorArgs ofASTType:srcAST toAgg:dstIR];
                        continue;
                        }
                    NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
                    BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                    if (srcW == dstW && srcSgn == dstSgn)
                        continue;
                    XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                                    : dstW < srcW ? XTIROpTrunc
                                                  : XTIROpBitcast;
                    XTIRValue* cv = [self emitInsnOpcode:op
                                                  result:dstIR
                                                operands:@[ [XTIROperand useWithValueId:((XTIRValue*)ctorArgs[i]).valueId] ]];
                    if (cv)
                        ctorArgs[i] = cv;
                    }
                }
            XTIRCallConv* conv =
                isym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                : isym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                       : [XTIRCallConv standard];
            NSMutableArray<XTIRValue*>* initArgs = [NSMutableArray array];
            [initArgs addObject:instance];           // self
            [initArgs addObjectsFromArray:ctorArgs]; // constructor args
            XTIRSymbolId iid = [self.module.symbols indexOfObjectIdenticalTo:isym];
            (void)[self emitCall:iid
                        callConv:conv
                       argValues:initArgs
                      resultType:nil]; // init returns void
            }
        // A class `new T` is a +1 owned temporary (task #123).
        [self registerOwnedTemp:instance];
        return instance;
        }

    // No init (or non-class new): alloc only, passing any args to the
    // allocator. A class instance still gets its vtable pointer set so
    // virtual/protocol dispatch works even without a user init.
    XTIRValue* instance = [self emitCall:sid
                                callConv:[XTIRCallConv standard]
                               argValues:args
                              resultType:resultIR];
    [self emitVtableInitFor:instance class:ci];
    // Zero strong-pointer ivars on the reused heap block (see the
    // with-init path above and private:docs/bugs/008).
    if (ci && [self classHasStrongPointerIvar:ci])
        [self emitZeroInitIvarsFor:instance class:ci];
    // Stamp the RTTI class id so a later downcast can read the type.
    if (ci)
        [self emitClassIdStampFor:instance class:ci];
    // Track only a class instance (+1); a non-class `new T[N]`/`new u16`
    // buffer is not ARC-managed.
    if (ci)
        [self registerOwnedTemp:instance];
    return instance;
    }

#pragma mark - Subscript (arr[i])

// Helper: compute the address of `base[idx]` as an SSA ptr value via
// ElementAddr. Handles a POINTER base (lower it, scale by its pointee)
// and an ARRAY base (decay the array lvalue to a pointer to its first
// element, scale by the element). Width coercion mirrors the
// ptr-arithmetic path from task #24 — ElementAddr expects a U16/I16 idx.
/****************************************************************************\
|* A class-typed base that is NOT a pointer is an instance LVALUE, not a
|* reference — and its "value", for member access or a method call, is its
|* ADDRESS.
|*
|* Two shapes reach here:
|*   Animal a;  a.describe()      a stack value instance (valueClassLocals)
|*   B@ bs = new B[8];  bs[i].v   an element of an INLINE class array
|*
|* The second one used to be silently wrong. `new B[N]` lays N instances out
|* inline, so `bs[i]` has type B (not B@) — sema strips the pointer at the
|* subscript. Lowering that as an *expression* yields Load(ElementAddr(..)),
|* i.e. it reads the element's own first word and treats it as a pointer to
|* the instance. Reads and writes then went through whatever garbage that
|* word held, and a method call was worse: a non-pointer class base that is
|* not a value instance was classified as a STATIC call, so `bs[i].set(...)`
|* compiled to a call with no `self` at all — no output, no diagnostic.
\****************************************************************************/
- (BOOL)isValueInstanceBase:(XTASTNode*)base
    {
    XTType* t = base.resolvedType;
    if (!t || t.kind != XTTypeKindClass)
        return NO;
    if ([t isKindOfClass:[XTPointerType class]])
        return NO;
    if ([base isKindOfClass:[XTIdentifierNode class]])
        return self.valueClassLocals[((XTIdentifierNode*)base).identName] != nil;
    return base.nodeKind == XTASTNodeKindSubscriptExpr;
    }

/****************************************************************************\
|* The self-pointer for a class-typed base. For an inline array element that
|* is the element's address; for everything else (a class POINTER, or a value
|* instance identifier, whose lowerIdentifier branch already yields its slot
|* address) the ordinary expression lowering is already the pointer.
\****************************************************************************/
- (nullable XTIRValue*)selfPointerForClassBase:(XTASTNode*)base
    {
    if (base.nodeKind == XTASTNodeKindSubscriptExpr && [self isValueInstanceBase:base])
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)base;
        return [self emitSubscriptAddress:sub.base
                                    index:sub.index
                                 location:sub.location];
        }
    return [self lowerExpression:base];
    }

- (nullable XTIRValue*)emitSubscriptAddress:(XTASTNode*)base
                                      index:(XTASTNode*)idx
                                   location:(XTSourceLocation*)loc
    {
    XTType* baseAST = base.resolvedType;
    XTIRValue* basePtr = nil;
    XTIRType* resultPtrIR = nil;
    XTType* weakElemAST = nil; // non-nil when the elements are weak slots

    if (baseAST && baseAST.kind == XTTypeKindPointer)
        {
        basePtr = [self lowerExpression:base];
        if (!basePtr)
            return nil;
        resultPtrIR = [self irTypeForASTType:baseAST at:loc];
        if (!resultPtrIR)
            return nil;
        }
    else if (baseAST && baseAST.kind == XTTypeKindArray && [baseAST isKindOfClass:[XTArrayType class]])
        {
        // Array base — decay to a pointer to element 0. ElementAddr
        // then scales the index by the element size.
        XTType* elemAST = ((XTArrayType*)baseAST).elementType;
        XTIRType* elemIR = [self irTypeForASTType:elemAST at:loc];
        if (!elemIR)
            return nil;
        // A weak element is a SLOT (Agg[prev, next, payload]) — the stride must
        // span the links, so the element pointer is typed with the whole slot and
        // the payload is picked out below.
        weakElemAST = [self astTypeIsWeakSlot:elemAST] ? elemAST : nil;
        if (weakElemAST)
            elemIR = [self weakSlotAggFor:elemIR];
        resultPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
        basePtr = [self decayArrayBaseToPtr:base elemPtr:resultPtrIR location:loc];
        if (!basePtr)
            return nil;
        }
    else
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: subscript base must be a pointer or array"];
        return nil;
        }

    XTIRValue* idxVal = [self lowerExpression:idx];
    if (!idxVal)
        return nil;
    XTType* idxAST = idx.resolvedType;
    if (idxAST && idxAST.byteWidth < 2)
        {
        idxVal = [self coerceValue:idxVal
                          fromType:idxAST
                            toType:[XTType u16Type]
                          location:loc];
        }
    // THIS is the path an ordinary `a[i]` takes — emitSubscriptAddress, not the
    // pointer-arithmetic ElementAddr below. Hooking only the latter emitted ten
    // checks into library code and NONE into the user's main, which is the kind
    // of gap that reads as "the check does not work" rather than "the check is
    // not there".
    // An array base knows its own length; a pointer base does not and has to
    // ask the allocation header.
    if (baseAST && baseAST.kind == XTTypeKindArray && [baseAST isKindOfClass:[XTArrayType class]]
        && ((XTArrayType*)baseAST).elementCount > 0)
        [self emitBoundsCheckArray:basePtr
                             index:idxVal
                             count:((XTArrayType*)baseAST).elementCount
                                at:loc];
    else
        [self emitBoundsCheckPtr:basePtr index:idxVal at:loc];
    XTIRValue* elemAddr = [self emitInsnOpcode:XTIROpElementAddr
                                        result:resultPtrIR
                                      operands:@[ [XTIROperand useWithValueId:basePtr.valueId],
                                                  [XTIROperand useWithValueId:idxVal.valueId] ]];
    if (!elemAddr || !weakElemAST)
        return elemAddr;
    // Past the two link words, onto the payload — so every caller's load/store
    // (which uses the ELEMENT's type) works unchanged.
    XTIRType* payload = [self irTypeForASTType:weakElemAST at:loc];
    if (!payload)
        return elemAddr;
    return [self emitFieldAddr:elemAddr
                    fieldIndex:2
                    resultType:[XTIRType ptrToType:payload
                                            window:XTIRWindowUnbanked]];
    }

// Decay an array lvalue to a pointer to its first element, typed
// `elemPtr`. Handles:
//   - bare identifiers (pinned local, global, or ivar)
//   - member-access chains (`obj.arr`, `self.arr`, `p->arr`)
//   - subscript expressions (nested `m[i][j]`)
//
// The storage address is the same regardless of pointee type, so
// AddrOf/FieldAddr is emitted directly with the element-pointer
// result (no bitcast). Mirrors addressOfStructLValue:'s resolution.
- (nullable XTIRValue*)decayArrayBaseToPtr:(XTASTNode*)base
                                   elemPtr:(XTIRType*)elemPtr
                                  location:(nullable XTSourceLocation*)loc
    {
    // Member access: `obj.arr` or `p->arr` — compute the field
    // address and return it with the element-pointer type so the
    // caller's ElementAddr scales by element width, not array width.
    if (base.nodeKind == XTASTNodeKindMemberAccess)
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)base;
        XTType* baseT = m.base.resolvedType;
        XTType* pointee = baseT;
        if (baseT && [baseT isKindOfClass:[XTPointerType class]])
            {
            pointee = ((XTPointerType*)baseT).pointeeType;
            }
        if (pointee && pointee.kind == XTTypeKindClass)
            {
            // Class ivar array: look up the ivar slot, lower the
            // receiver expression, emit FieldAddr with elemPtr type.
            XTIRClassInfo* ci = self.classesByName[pointee.displayName];
            if (!ci)
                {
                [self softFailLoweringAt:loc
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: unknown class '%@'", pointee.displayName]];
                return nil;
                }
            NSNumber* slot = nil;
            for (XTIRClassInfo* ic = ci; ic != nil; ic = ic.parent)
                {
                slot = ic.ivarFieldIndex[m.memberName];
                if (slot)
                    break;
                }
            if (!slot)
                {
                [self softFailLoweringAt:loc
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: class '%@' has no ivar '%@'",
                                                       pointee.displayName, m.memberName]];
                return nil;
                }
            XTIRValue* basePtr = [self lowerExpression:m.base];
            if (!basePtr)
                return nil;
            return [self emitFieldAddr:basePtr
                            fieldIndex:slot.unsignedIntegerValue
                            resultType:elemPtr];
            }
        if (pointee && pointee.kind == XTTypeKindStruct && [pointee isKindOfClass:[XTStructType class]])
            {
            // Struct field array: compute the field address using
            // the parent struct's address (recurse for nesting),
            // then FieldAddr for the array field with elemPtr type.
            XTStructType* st = (XTStructType*)pointee;
            NSUInteger fieldIndex = 0;
            if (![self structType:st
                       fieldNamed:m.memberName
                            index:&fieldIndex
                          astType:NULL])
                {
                [self softFailLoweringAt:loc
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: struct '%@' has no field '%@'",
                                                       pointee.displayName, m.memberName]];
                return nil;
                }
            // Arrow form OR a pointer base written with `.` (the sugar):
            // the base VALUE is the struct's address — `c.buf[i]` through a
            // `C*` local used to fall into addressOfStructLValue on the bare
            // identifier and die with "neither a pinned local, global, nor
            // ivar" (blewit finding #6). Mirrors addressOfStructLValue's own
            // member-access branch.
            BOOL baseIsPointer = (baseT && [baseT isKindOfClass:[XTPointerType class]]);
            XTIRValue* baseAddr = nil;
            if (m.isArrow || baseIsPointer)
                {
                baseAddr = [self lowerExpression:m.base];
                }
            else
                {
                baseAddr = [self addressOfStructLValue:m.base];
                }
            if (!baseAddr)
                return nil;
            return [self emitFieldAddr:baseAddr
                            fieldIndex:fieldIndex
                            resultType:elemPtr];
            }
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: array subscript base must be a struct or class member"];
        return nil;
        }
    // Subscript expression `m[i]` used as the base of another
    // subscript `m[i][j]`: lower the outer subscript's address
    // via emitSubscriptAddress, which gives us a pointer to the
    // element at m[i]; the enclosing ElementAddr j scales by
    // sizeof(elem) internally, so we can return the raw pointer.
    if (base.nodeKind == XTASTNodeKindSubscriptExpr)
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)base;
        return [self emitSubscriptAddress:sub.base
                                    index:sub.index
                                 location:sub.location];
        }
    if (base.nodeKind != XTASTNodeKindIdentifier)
        {
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: array subscript base must be a simple identifier"];
        return nil;
        }
    XTIdentifierNode* idn = (XTIdentifierNode*)base;
    XTIRPinnedLocal* pl = self.pinnedLocals[idn.identName];
    if (pl)
        {
        return [self emitInsnOpcode:XTIROpAddrOf
                             result:elemPtr
                           operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
        }
    NSNumber* gid = self.globalsByName[idn.identName];
    if (gid)
        {
        return [self emitInsnOpcode:XTIROpAddrOf
                             result:elemPtr
                           operands:@[ [XTIROperand symWithSymbolId:gid.unsignedIntegerValue] ]];
        }
    if (self.currentClassInfo && self.currentSelf)
        {
        NSNumber* slot = nil;
        for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
            {
            slot = ci.ivarFieldIndex[idn.identName];
            if (slot)
                break;
            }
        if (slot)
            {
            return [self emitFieldAddr:self.currentSelf
                            fieldIndex:slot.unsignedIntegerValue
                            resultType:elemPtr];
            }
        }
    [self softFailLoweringAt:loc
                 withMessage:[NSString stringWithFormat:
                                           @"lowering: array '%@' is neither a pinned local, global, nor ivar",
                                           idn.identName]];
    return nil;
    }

- (nullable XTIRValue*)lowerSubscriptExpr:(XTSubscriptExprNode*)node
    {
    XTIRValue* addr = [self emitSubscriptAddress:node.base
                                           index:node.index
                                        location:node.location];
    if (!addr)
        return nil;
    XTIRType* resultIR = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIR)
        return nil;
    return [self emitLoad:addr pointeeType:resultIR];
    }

#pragma mark - Intrinsics (va_start / va_arg_<T> / va_end)

// Lower a sema-recognised intrinsic call. Sema stamps
// `resolvedMangledName = "__intrinsic_<name>"` on every call that
// resolves to a varargs intrinsic; the lowering replaces it with
// pure IR (no symbol call) so the verifier doesn't see a dangling
// Sym reference.
//
// The varargs cursor argument is always a plain u8 identifier
// (sema enforces this via the cursor-type check). va_start
// rebinds the local to Const #0:U8; va_arg_<T> reads the
// "current value" (a stub returning Const #0:T for now —
// real buffer reads are a follow-up task) and advances the
// cursor by sizeof(T). va_end is a no-op.
// Lazily create (and cache) the shared variadic-argument buffer
// `__xtc_va_buf`: one 8-byte slot per passed vararg (8 covers the
// widest scalar / a host pointer, so the layout is arch-neutral — the
// per-value Store/Load widths differ by backend but pack and read agree
// within a backend). 16 slots is plenty for any corpus printf.
- (XTIRSymbolId)varargBufferSymbol
    {
    static NSString* const kName = @"__xtc_va_buf";
    XTIRSymbol* existing = [self.module symbolForName:kName];
    if (existing)
        {
        return [self.module.symbols indexOfObjectIdenticalTo:existing];
        }
    XTIRLayout* bufLayout = [[XTIRLayout alloc] initWithSize:128
                                                   alignment:1
                                                      fields:@[]];
    [self.module addLayout:bufLayout];
    XTIRType* bufTy = [XTIRType aggWithLayout:bufLayout];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:kName
                                                type:bufTy
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    return [self.module addSymbol:sym];
    }

// Stride per vararg slot in `__xtc_va_buf` (bytes). Fixed so the
// arch-neutral cursor arithmetic matches on both backends.
static const NSUInteger kVarargSlotBytes = 8;

// Pack a call's variadic arguments (everything past the callee's fixed
// params) into `__xtc_va_buf`, one per 8-byte slot, so the callee's
// `va_arg_<T>` reads them back. Returns the fixed-arg prefix (the args
// actually passed in registers / on the stack). `args` is the full
// lowered argument list; `fixedCount` is the number of declared params.
- (NSArray<XTIRValue*>*)packVarargsFrom:(NSArray<XTIRValue*>*)args
                             fixedCount:(NSUInteger)fixedCount
    {
    if (args.count <= fixedCount)
        return args;
    XTIRSymbolId bufSid = [self varargBufferSymbol];
    XTIRType* u8 = [XTIRType u8Type];
    XTIRType* u8Ptr = [XTIRType ptrToType:u8 window:XTIRWindowUnbanked];
    NSUInteger byteOff = 0;
    for (NSUInteger i = fixedCount; i < args.count; i++)
        {
        XTIRValue* bufPtr = [self emitInsnOpcode:XTIROpAddrOf
                                          result:u8Ptr
                                        operands:@[ [XTIROperand symWithSymbolId:bufSid] ]];
        XTIRValue* idx = [self allocateValueOfType:[XTIRType u16Type] atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:idx
                                                       operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                                       value:(int64_t)byteOff] ]
                                                         dbgLoc:nil]];
        XTIRValue* slotPtr = [self emitInsnOpcode:XTIROpElementAddr
                                           result:u8Ptr
                                         operands:@[ [XTIROperand useWithValueId:bufPtr.valueId],
                                                     [XTIROperand useWithValueId:idx.valueId] ]];
        // Default-argument promotion: a u8/i8/bool vararg stored at its native
        // 1-byte width leaves the slot's high byte holding stale buffer
        // data, which va_arg_u16 / va_arg_i16 (the `%u` / `%d` read width)
        // then picks up. Widen narrow integers to 2 bytes before the store
        // — u8 → u16 (ZExt), i8 → i16 (SExt) — so the read width's bytes
        // are well-defined. va_arg_u8 / `%c` still reads the correct low
        // byte. Wider integers, float/double and pointers store unchanged.
        //
        // Bool counts as narrow here even though XTIRTypeKindIsInteger says
        // otherwise: it is a 1-byte value and needs the same widening.
        // Without it `printf("%d", a == b)` read the neighbouring stale byte
        // — 0xBE01 on a little-endian target whose slot still held 0xBEEF,
        // and a plain 256 on big-endian m68k, where the live byte IS the
        // high half of the 16 bits `%d` reads.
        XTIRValue* toStore = args[i];
        XTIRType* vt = toStore.type;
        BOOL narrowInt = vt && vt.byteWidth < 2 && (XTIRTypeKindIsInteger(vt.kind) || vt.kind == XTIRTypeKindBool);
        if (narrowInt)
            {
            BOOL sgn = XTIRTypeKindIsSigned(vt.kind);
            XTIRType* promoted = sgn ? [XTIRType i16Type] : [XTIRType u16Type];
            XTIRValue* cv = [self emitInsnOpcode:(sgn ? XTIROpSExt : XTIROpZExt)
                                          result:promoted
                                        operands:@[ [XTIROperand useWithValueId:toStore.valueId] ]];
            if (cv)
                toStore = cv;
            vt = toStore.type;
            }
        [self emitStore:slotPtr value:toStore consumesOwnership:NO];
        // Struct-by-value vararg: the loaded Agg value carries sizeof(T)
        // bytes — Store of an Agg copies them all (backend uses the value's
        // byteWidth). The cursor must advance by exactly sizeof(T), not the
        // fixed 8-byte slot, so that va_arg(ap, T@) in the callee both
        // points at the right bytes AND can read a following scalar from
        // its own kVarargSlotBytes-aligned position. Scalars / pointers
        // stay on the fixed 8-byte stride for cross-fixture compatibility.
        if (vt && vt.kind == XTIRTypeKindAgg && vt.byteWidth > 0)
            {
            byteOff += vt.byteWidth;
            }
        else
            {
            byteOff += kVarargSlotBytes;
            }
        }
    return [args subarrayWithRange:NSMakeRange(0, fixedCount)];
    }

// Memory-backed va_* cursor access. The cursor is a pinned local (a
// frame slot allocated by the pre-scan), so its loop-carried byte offset
// survives loops / if-joins through the Mem token instead of fragile SSA
// phis. Read = AddrOf(slot) + Load; write = AddrOf(slot) + Store.
- (nullable XTIRValue*)loadVarargCursor:(XTIRPinnedLocal*)pin
    {
    XTIRType* ptrTy = [XTIRType ptrToType:pin.type window:XTIRWindowUnbanked];
    XTIRValue* addr = [self emitInsnOpcode:XTIROpAddrOf
                                    result:ptrTy
                                  operands:@[ [XTIROperand useWithValueId:pin.valueId] ]];
    if (!addr)
        return nil;
    return [self emitLoad:addr pointeeType:pin.type];
    }

- (void)storeVarargCursor:(XTIRValue*)val into:(XTIRPinnedLocal*)pin
    {
    if (!val)
        return;
    XTIRType* ptrTy = [XTIRType ptrToType:pin.type window:XTIRWindowUnbanked];
    XTIRValue* addr = [self emitInsnOpcode:XTIROpAddrOf
                                    result:ptrTy
                                  operands:@[ [XTIROperand useWithValueId:pin.valueId] ]];
    if (!addr)
        return;
    [self emitStore:addr value:val];
    }

- (nullable XTIRValue*)lowerIntrinsicCall:(XTCallExprNode*)node
    {
    NSString* mangled = node.resolvedMangledName;
    NSString* intrinsic = [mangled substringFromIndex:[@"__intrinsic_" length]];

    // Library-level ARC primitives: lower the pointer argument and emit
    // the same Retain / Release opcode the compiler inserts for typed
    // strong references. Container code calls these to refcount its
    // type-erased `pointer` slots (which ARC never tracks). emitRetain /
    // emitRelease are null-safe in the runtime and carry the bank byte,
    // so this fully replaces the old inline-asm `JSR _obj_retain` helpers
    // — and works on arm64, where inline asm is a no-op.
    if ([intrinsic isEqualToString:@"__arc_retain"] || [intrinsic isEqualToString:@"__arc_release"])
        {
        if (node.arguments.count != 1)
            return nil; // sema already erred
        XTIRValue* p = [self lowerExpression:node.arguments[0]];
        if (!p)
            return nil;
        if ([intrinsic isEqualToString:@"__arc_retain"])
            [self emitRetain:p];
        else
            [self emitRelease:p];
        return nil;
        }

    // Cursor argument — first arg, always an identifier per sema.
    // Defensive: if the AST shape differs for some reason, fall
    // back to soft-fail rather than crashing.
    NSString* cursorName = nil;
    if (node.arguments.count >= 1 && node.arguments[0].nodeKind == XTASTNodeKindIdentifier)
        {
        cursorName = ((XTIdentifierNode*)node.arguments[0]).identName;
        }
    // The pre-scan memory-backs the cursor (pinned 1-byte slot) so its
    // loop-carried offset flows through Mem, not SSA phis. When present,
    // load/store the cursor through the slot; otherwise fall back to the
    // SSA-local binding (defensive — a cursor sema didn't let us pin).
    XTIRPinnedLocal* cursorPin = cursorName ? self.pinnedLocals[cursorName] : nil;

    // va_end — pure no-op. No mem token change, no value, no
    // cursor mutation.
    if ([intrinsic isEqualToString:@"va_end"])
        {
        return nil;
        }

    // bank(BANK_TYPE, idx) builtin — returns a raw:u8@ (Ptr(U8))
    // addressing byte 0 of the requested window in bank `idx`. Sema
    // validated arg shape; BANK_TYPE is always a compile-time int
    // literal in [0,2]. Lower to a Call to the runtime helper
    // `_xtc_bank(u8 type, u8 idx)` — each backend's corpus stub
    // implements it: xt6502 returns the 3-byte (lo, hi, bank) pointer
    // with the matching window base ($A000 BANK_DATA, $6000 BANK_CODE);
    // arm64 returns a pointer into a (lazy) per-(type, idx) 12 KB
    // malloc'd region so reads/writes round-trip. The corpus harness
    // detects this helper symbol the same way it does `_xtc_new_*`.
    if ([intrinsic isEqualToString:@"bank"])
        {
        if (node.arguments.count != 2)
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: 'bank' intrinsic expects 2 args"];
            return nil;
            }
        XTIRValue* typeV = [self lowerExpression:node.arguments[0]];
        if (!typeV)
            return nil;
        typeV = [self coerceValue:typeV
                         fromType:node.arguments[0].resolvedType
                           toType:[XTType u8Type]
                         location:node.location];
        XTIRValue* idxV = [self lowerExpression:node.arguments[1]];
        if (!idxV)
            return nil;
        idxV = [self coerceValue:idxV
                        fromType:node.arguments[1].resolvedType
                          toType:[XTType u8Type]
                        location:node.location];
        XTIRSymbolId sid = [self runtimeHelperSymbolNamed:@"_xtc_bank"];
        XTIRType* u8 = [XTIRType u8Type];
        XTIRType* retIR = [XTIRType ptrToType:u8 window:XTIRWindowUnbanked];
        return [self emitCall:sid
                     callConv:[XTIRCallConv standard]
                    argValues:@[ typeV, idxV ]
                   resultType:retIR];
        }

    // va_start — reset the cursor to 0.
    if ([intrinsic isEqualToString:@"va_start"])
        {
        if (!cursorName)
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: va_start cursor must be an identifier"];
            return nil;
            }
        if (cursorPin)
            {
            // Abstract op — a per-target lowering resets the native va_list /
            // pack-buffer cursor (XTIROptVaArgExpand for the default path; the
            // arm9/arm64 backend lowers it natively).
            XTIRType* ptrTy = [XTIRType ptrToType:cursorPin.type window:XTIRWindowUnbanked];
            XTIRValue* cursorAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                  result:ptrTy
                                                operands:@[ [XTIROperand useWithValueId:cursorPin.valueId] ]];
            [self emitVaMemOp:XTIROpVaStart cursorAddr:cursorAddr resultType:nil];
            return nil;
            }
        // Defensive (no pinned cursor): SSA-bind the cursor to 0.
        XTIRType* u8 = [XTIRType u8Type];
        XTIRValue* zero = [self allocateValueOfType:u8 atSite:self.currentBlock];
        XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                 result:zero
                                               operands:@[ [XTIROperand immIWithType:u8 value:0] ]
                                                 dbgLoc:nil];
        [self.currentBlock appendInstruction:cz];
        self.locals[cursorName] = zero;
        return nil;
        }

    // va_arg_<T> — return a zero of the resolved type, advance
    // the cursor by sizeof(T). The lookup table for T → width is
    // by suffix; pointer-typed variants are always 2 bytes
    // (assumed unbanked for now).
    NSUInteger advanceBy = 0;
    NSDictionary<NSString*, NSNumber*>* widthBySuffix = @{
        @"va_arg_u8" : @1,
        @"va_arg_i8" : @1,
        @"va_arg_u16" : @2,
        @"va_arg_i16" : @2,
        @"va_arg_u32" : @4,
        @"va_arg_i32" : @4,
        @"va_arg_u64" : @8,
        @"va_arg_i64" : @8,
        @"va_arg_float" : @4,
        @"va_arg_double" : @8,
        @"va_arg_ptr" : @2,
        @"va_arg_string" : @2,
        @"va_arg_struct_ptr" : @2,
    };
    NSNumber* w = widthBySuffix[intrinsic];
    if (!w)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unsupported intrinsic '%@'", intrinsic]];
        return nil;
        }
    (void)w;
    BOOL isStructPtr = [intrinsic isEqualToString:@"va_arg_struct_ptr"];
    advanceBy = kVarargSlotBytes; // one fixed-size slot per vararg

    // Read the next vararg from `__xtc_va_buf[cursor]`, where cursor is
    // the running byte offset (slots are kVarargSlotBytes apart, matching
    // packVarargsFrom:). Loading the result type's width from the slot
    // recovers exactly what the caller stored. If there's no cursor
    // (sema enforces va_start, so defensive only), fall back to zero.
    //
    // STRUCT-BY-VALUE varargs are the exception: the caller copied the
    // struct's raw bytes into the slot at sizeof(T), and the callee
    // wants a typed pointer INTO the buffer (not a load of the slot's
    // bytes-as-a-pointer). Return slotPtr directly, then advance the
    // cursor by exactly sizeof(T) so a following slot lands at the
    // right offset.
    XTIRType* resultIR = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIR)
        return nil;

    // Native path: emit an abstract VaArg op carrying the cursor slot + the
    // result type. A per-target lowering expands it — XTIROptVaArgExpand for the
    // default pack-buffer path, or the arm9/arm64 backend's native AAPCS read.
    // Requires the pinned cursor (the normal case — va_start pins it); the buffer
    // expansion below is the defensive no-pin fallback.
    if (cursorPin)
        {
        XTIRType* ptrTy = [XTIRType ptrToType:cursorPin.type window:XTIRWindowUnbanked];
        XTIRValue* cursorAddr = [self emitInsnOpcode:XTIROpAddrOf
                                              result:ptrTy
                                            operands:@[ [XTIROperand useWithValueId:cursorPin.valueId] ]];
        // A CLASS-pointer read must NOT put Ptr(Agg) on the abstract VaArg:
        // the expander's only way to spot struct-BY-VALUE (typed pointer into
        // the buffer, advance by sizeof) is that same Ptr(Agg) shape, and a
        // class reference given that treatment dispatched through the buffer
        // bytes (string_format, %@). Read the slot as a plain pointer VALUE
        // and Bitcast to the class type after.
        BOOL classRead = !isStructPtr && resultIR.kind == XTIRTypeKindPtr && resultIR.pointeeType && resultIR.pointeeType.kind == XTIRTypeKindAgg;
        XTIRType* vaT = classRead
                            ? [XTIRType ptrToType:[XTIRType u8Type] window:XTIRWindowUnbanked]
                            : resultIR;
        XTIRValue* raw = [self emitVaMemOp:XTIROpVaArg cursorAddr:cursorAddr resultType:vaT];
        if (!classRead || !raw)
            return raw;
        return [self emitInsnOpcode:XTIROpBitcast
                             result:resultIR
                           operands:@[ [XTIROperand useWithValueId:raw.valueId] ]];
        }

    XTIRValue* resultVal = nil;
    XTIRValue* cur = cursorName ? self.locals[cursorName] : nil;
    if (cur)
        {
        XTIRType* u8t = [XTIRType u8Type];
        XTIRType* u8Ptr = [XTIRType ptrToType:u8t window:XTIRWindowUnbanked];
        XTIRSymbolId bufSid = [self varargBufferSymbol];
        XTIRValue* bufPtr = [self emitInsnOpcode:XTIROpAddrOf
                                          result:u8Ptr
                                        operands:@[ [XTIROperand symWithSymbolId:bufSid] ]];
        XTIRValue* idx = [self coerceValue:cur
                                  fromType:[XTType u8Type]
                                    toType:[XTType u16Type]
                                  location:node.location];
        XTIRValue* slotPtr = [self emitInsnOpcode:XTIROpElementAddr
                                           result:u8Ptr
                                         operands:@[ [XTIROperand useWithValueId:bufPtr.valueId],
                                                     [XTIROperand useWithValueId:idx.valueId] ]];
        if (isStructPtr)
            {
            // Hand back a Ptr(T) into the buffer. Cast the u8@ slot
            // address to T@ via Bitcast (same bytes, different pointee
            // type) so `(@sp).field` derefs through the right layout.
            resultVal = [self emitInsnOpcode:XTIROpBitcast
                                      result:resultIR
                                    operands:@[ [XTIROperand useWithValueId:slotPtr.valueId] ]];
            // Cursor stride = sizeof(T). Pointee's layout.size is the
            // struct width the packer used.
            XTIRType* pointee = resultIR.pointeeType;
            if (pointee && pointee.byteWidth > 0)
                {
                advanceBy = pointee.byteWidth;
                }
            }
        else if (XTIRTypeKindIsInteger(resultIR.kind) && resultIR.byteWidth < 2)
            {
            // The packer widens a narrow (u8/i8) vararg to 2 bytes (ZExt/SExt)
            // so the slot's bytes are well-defined. Read at that widened width
            // and truncate — endian-agnostic. A direct 1-byte load would pick
            // the high (zero) byte on a big-endian target (m68k).
            BOOL sgn = XTIRTypeKindIsSigned(resultIR.kind);
            XTIRType* wide = sgn ? [XTIRType i16Type] : [XTIRType u16Type];
            XTIRValue* wv = [self emitLoad:slotPtr pointeeType:wide];
            resultVal = [self emitInsnOpcode:XTIROpTrunc
                                      result:resultIR
                                    operands:@[ [XTIROperand useWithValueId:wv.valueId] ]];
            }
        else
            {
            resultVal = [self emitLoad:slotPtr pointeeType:resultIR];
            }
        }
    if (!resultVal)
        {
        if (resultIR.kind == XTIRTypeKindPtr)
            {
            XTIRType* u16 = [XTIRType u16Type];
            XTIRValue* zeroInt = [self allocateValueOfType:u16 atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                             result:zeroInt
                                                           operands:@[ [XTIROperand immIWithType:u16 value:0] ]
                                                             dbgLoc:nil]];
            resultVal = [self emitInsnOpcode:XTIROpIntToPtr
                                      result:resultIR
                                    operands:@[ [XTIROperand useWithValueId:zeroInt.valueId] ]];
            }
        else
            {
            resultVal = [self allocateValueOfType:resultIR atSite:self.currentBlock];
            [self.currentBlock appendInstruction:
                                   [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                             result:resultVal
                                                           operands:@[ [XTIROperand immIWithType:resultIR value:0] ]
                                                             dbgLoc:nil]];
            }
        }

    // Advance the cursor by one slot: cursor = cursor + kVarargSlotBytes.
    // The cursor is a u8 (the buffer is small). Reuse the value just read
    // (`cur`) so the add chains off the live offset, then write the new
    // offset back — to the pinned slot (Store) or the SSA binding.
    if (cur)
        {
        XTIRType* u8 = [XTIRType u8Type];
        XTIRValue* delta = [self allocateValueOfType:u8 atSite:self.currentBlock];
        XTIRInsn* dz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                 result:delta
                                               operands:@[ [XTIROperand immIWithType:u8 value:(int64_t)advanceBy] ]
                                                 dbgLoc:nil];
        [self.currentBlock appendInstruction:dz];
        XTIRValue* next = [self emitInsnOpcode:XTIROpAdd
                                        result:u8
                                      operands:@[ [XTIROperand useWithValueId:cur.valueId],
                                                  [XTIROperand useWithValueId:delta.valueId] ]];
        if (next)
            {
            if (cursorPin)
                [self storeVarargCursor:next into:cursorPin];
            else if (cursorName)
                self.locals[cursorName] = next;
            }
        }

    return resultVal;
    }

#pragma mark - Call

- (nullable XTIRValue*)lowerCallExpr:(XTCallExprNode*)node
    {
    // A block-typed callee was rewritten by sema into `.invoke` dispatch.
    // private:docs/bugs/074.
    if (node.indirectRewrite)
        return [self lowerExpression:node.indirectRewrite];
    // Intrinsic dispatch — sema stamps `__intrinsic_<name>` on the
    // mangledName for va_start / va_arg_<T> / va_end (and a few
    // others). These have no real symbol; the lowering replaces
    // each call with pure IR. Branch before the symbol lookup so
    // the absent symbol doesn't trigger a soft-fail.
    NSString* mangled = node.resolvedMangledName;
    if (mangled && [mangled hasPrefix:@"__intrinsic_"])
        {
        return [self lowerIntrinsicCall:node];
        }

    // Indirect call through a function pointer (`fp(args)`). Sema sets
    // isIndirectCall when calleeName resolves to a local / parameter /
    // global of `FuncType@` type rather than a function symbol. Lower
    // that variable to its pointer value and dispatch through it. Args
    // are already cast to the signature's types by sema, so they lower
    // directly. (Reaches here only as a free-call form — method calls
    // through a member fn-pointer would route via lowerMethodCallExpr.)
    // Call through a bound method (`^`): split the fat pointer into its two
    // words and dispatch through `code` with `recv` prepended as the implicit
    // self — the one uniform ABI, `code(recv, args…)`, which is also what the
    // `@`→`^` widening thunks are shaped to satisfy.
    if (node.isBoundCall)
        {
        // Prefer the `^`'s SSA VALUE over its address. A `^` is an aggregate,
        // and every aggregate PARAM is pinned to a frame slot at fn entry so
        // that `.field` access can resolve through an address — which makes
        // lowerIdentifier read a bare reference via `AddrOf; Load`. That AddrOf
        // is what the xt6502 backend keys on to force the value into ZERO PAGE
        // (address-taken values need a real 16-bit address, which the hidden SP
        // stack can't give). And ZP is exactly the storage a callee reuses for
        // its own locals — so a `^` held across a call (e.g. `Array.mapped`'s
        // per-element `f(get(i))`) got its recv clobbered by the transform's
        // deep call chain, dispatching call N+1 through a wrecked pointer.
        //
        // We only need the field VALUES (recv, code) to make the call, and
        // AggExtract works on the value directly — no address required. Taking
        // the SSA value keeps no `AddrOf` in the IR, so the `^` stays on the SP
        // frame, out of the callees' reach. The AddrOf+Load path remains for
        // any `^` that genuinely has no live SSA binding (a field-resident one).
        // See private:docs/bugs/012.
        // A callee written as an EXPRESSION (`tbl[0](5)`) is evaluated here;
        // everything below works from the resulting VALUE, so the two callee
        // forms share the whole dispatch. private:docs/bugs/074.
        XTIRValue* fat = node.calleeExpr ? [self lowerExpression:node.calleeExpr]
                                         : self.locals[node.calleeName];
        if (node.calleeExpr && !fat)
            return nil;
        if (!node.calleeExpr && (!fat || !fat.type || fat.type.kind != XTIRTypeKindAgg))
            {
            XTIdentifierNode* calleeId =
                [[XTIdentifierNode alloc] initWithName:node.calleeName
                                              location:node.location];
            fat = [self lowerIdentifier:calleeId];
            }
        if (!fat)
            return nil;

        XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                      window:XTIRWindowUnbanked];
        XTIRValue* recv = [self emitInsnOpcode:XTIROpAggExtract
                                        result:ptrT
                                      operands:@[ [XTIROperand useWithValueId:fat.valueId],
                                                  [XTIROperand immIWithType:[XTIRType u16Type]
                                                                      value:0] ]];
        XTIRValue* code = [self emitInsnOpcode:XTIROpAggExtract
                                        result:ptrT
                                      operands:@[ [XTIROperand useWithValueId:fat.valueId],
                                                  [XTIROperand immIWithType:[XTIRType u16Type]
                                                                      value:1] ]];
        if (!recv || !code)
            return nil;

        NSMutableArray<XTIRValue*>* bargs = [NSMutableArray array];
        [bargs addObject:recv]; // implicit self
        for (XTASTNode* a in node.arguments)
            {
            XTIRValue* av = [self lowerExpression:a];
            if (!av)
                return nil;
            [bargs addObject:av];
            }
        XTIRType* bResult = nil;
        if (node.resolvedType && !node.resolvedType.isVoid)
            {
            bResult = [self irTypeForASTType:node.resolvedType at:node.location];
            if (!bResult)
                return nil;
            }
        return [self emitCallIndirect:code argValues:bargs resultType:bResult];
        }

    if (node.isIndirectCall)
        {
        XTIRValue* fnPtr = nil;
        if (node.calleeExpr)
            {
            fnPtr = [self lowerExpression:node.calleeExpr];
            }
        else
            {
            XTIdentifierNode* calleeId =
                [[XTIdentifierNode alloc] initWithName:node.calleeName
                                              location:node.location];
            fnPtr = [self lowerIdentifier:calleeId];
            }
        if (!fnPtr)
            return nil;
        NSMutableArray<XTIRValue*>* iargs = [NSMutableArray array];
        for (XTASTNode* a in node.arguments)
            {
            XTIRValue* av = [self lowerExpression:a];
            if (!av)
                return nil;
            [iargs addObject:av];
            }
        XTIRType* iResult = nil;
        if (node.resolvedType && !node.resolvedType.isVoid)
            {
            iResult = [self irTypeForASTType:node.resolvedType at:node.location];
            if (!iResult)
                return nil;
            }
        return [self emitCallIndirect:fnPtr argValues:iargs resultType:iResult];
        }

    // Resolve callee in the module's symbol table.
    NSString* targetName = node.resolvedMangledName ?: node.calleeName;
    // A stamped `resolvedClassName` means sema resolved this to a METHOD, so
    // the free-function table must not be consulted at all — not for the bare
    // name (the fallback below already knew that) and not for the mangled name
    // either, which is unqualified and collides with a same-named global. That
    // second lookup is how a user's `void add(i32)` silently captured every
    // class's own `add` (bug 040).
    XTIRSymbol* sym = node.resolvedClassName.length > 0
                          ? nil
                          : [self.module symbolForName:targetName];
    if (!sym && node.resolvedClassName.length == 0)
        {
        // Try the bare name as a fallback — but NOT when sema stamped a
        // `resolvedClassName` (a `use`-promoted class method). libc/free
        // functions are the lowest-precedence layer: a same-named free symbol
        // (e.g. the auto-imported libc `rand(void)` proto) must not shadow the
        // class method sema explicitly chose. Leaving sym nil routes us to the
        // use-promoted branch below.
        sym = [self.module symbolForName:node.calleeName];
        }
    if (!sym && self.currentClassInfo && self.currentSelf)
        {
        // Implicit-self sibling-method call: `foo(args)` with no
        // receiver inside a method body, where `foo` is a method of
        // the current class (or an ancestor). The parser models this
        // as a bare free-function call, so it lands here instead of
        // lowerMethodCallExpr:. Resolve `<class>$<method>` walking
        // parents and emit it with `self` prepended — the same shape
        // lowerMethodCallExpr: produces for `recv.foo(args)`.
        NSString* methodMangled = node.resolvedMangledName ?: node.calleeName;
        for (XTIRClassInfo* ci = self.currentClassInfo; ci != nil; ci = ci.parent)
            {
            NSString* cand = [NSString stringWithFormat:@"%@$%@",
                                                        ci.className, methodMangled];
            XTIRSymbol* msym = [self.module symbolForName:cand];
            if (!msym)
                continue;
            NSMutableArray<XTIRValue*>* margs = [NSMutableArray array];
            // Only INSTANCE methods take a `self` parameter. A static
            // sibling method reaches the class's `__sdata` singleton on
            // its own (its signature has no self slot — see paramNames
            // in lowerClass:), so prepending self here would push an
            // extra arg the callee never reads, shifting every real
            // param by one pointer. (printf → putChar, both static, hit
            // exactly this: putChar read self's low byte as its char.)
            BOOL isStatic = msym.attributes[@"static"].boolValue;
            if (!isStatic)
                {
                [margs addObject:self.currentSelf]; // implicit self
                }
            for (XTASTNode* a in node.arguments)
                {
                XTIRValue* av = [self lowerExpression:a];
                if (!av)
                    return nil;
                [margs addObject:av];
                }
            // Coerce each explicit argument to the callee's matching
            // parameter type. The VTblDispatch and direct-Call paths below
            // push each arg at its own IR width; without this a narrow arg
            // (a byte literal, or a u8 passed to an i16 param) is pushed one
            // byte where the callee reads two, shifting every later param —
            // the dispatched method then reads a garbage frame (e.g.
            // `inline:getPixel(cx, cy)` with `cy` a u8 → wrong pixel → 0,
            // which hung Gfx.floodFill). The explicit-receiver call path
            // coerces via resolvedType the same way; this brings the
            // implicit-self / inline-vtable path to parity. (docs/bugs)
            if (msym.function)
                {
                NSUInteger selfOff = isStatic ? 0 : 1;
                NSUInteger nParam = msym.function.paramTypes.count; // fixed + Mem
                for (NSUInteger k = 0; k < node.arguments.count; k++)
                    {
                    NSUInteger pIdx = selfOff + k;
                    if (pIdx + 1 >= nParam)
                        break; // reached Memory token / varargs
                    XTIRType* dstIR = msym.function.paramTypes[pIdx];
                    XTType* srcAST = [node.arguments[k] resolvedType];
                    if (!srcAST || dstIR.kind == XTIRTypeKindVoid || dstIR.kind == XTIRTypeKindPtr)
                        continue;
                    // NEVER integer-extend an aggregate. A `^` parameter is an Agg, and this
                    // loop would otherwise emit `ZExt %agg` from the ARGUMENT's pointer width.
                    // An fn-pointer arg here is a `@`->`^` widening; any other aggregate is
                    // already the value the callee wants.
                    if (dstIR.kind == XTIRTypeKindAgg)
                        {
                        [self widenBoundArgAt:pIdx in:margs ofASTType:srcAST toAgg:dstIR];
                        continue;
                        }
                    NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
                    BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                    if (srcW == dstW && srcSgn == dstSgn)
                        continue;
                    XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                                    : dstW < srcW ? XTIROpTrunc
                                                  : XTIROpBitcast;
                    XTIRValue* cv = [self emitInsnOpcode:op
                                                  result:dstIR
                                                operands:@[ [XTIROperand useWithValueId:((XTIRValue*)margs[pIdx]).valueId] ]];
                    if (cv)
                        margs[pIdx] = cv;
                    }
                }
            XTIRType* mResult = nil;
            if (node.resolvedType && !node.resolvedType.isVoid)
                {
                mResult = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!mResult)
                    return nil;
                }
            // A bare `foo()` in a method body IS `self.foo()`, so it must
            // dispatch on self's RUNTIME class — not the lexically enclosing
            // one. Resolving it statically here meant a base class's
            // template method called its own implementation and ignored the
            // subclass override (`A.viaSelf` calling `A.f` even on a `B`),
            // which silently breaks the template-method pattern that any UI
            // toolkit is built on: base `display()` calling `drawRect()`.
            //
            // This costs nothing when nothing overrides `foo`: sema only
            // allocates a vtable slot to an override ROOT, so a
            // never-overridden method has no slot and still takes the direct
            // `emitCall` below. Dispatch appears exactly where it's needed.
            //
            // Subsumes the old `inline:foo()` case — `inline:` on a method
            // with a slot also had to dispatch virtually, since without real
            // body-inlining a static resolution would pick the authoring
            // class's override (Gfx.plot rather than Gfx8.plot).
            XTIRClassInfo* selfCi = self.currentClassInfo ?: ci;
            if (!isStatic && selfCi.needsVtable)
                {
                // §4.2 first: a category method on an imported class has a chain
                // slot, never a vtable one.
                NSNumber* cslot = selfCi.catSlot[methodMangled] ?: ci.catSlot[methodMangled];
                NSString* canchor = selfCi.catChainAnchor ?: ci.catChainAnchor;
                if (cslot && canchor.length)
                    {
                    return [self emitCatDispatch:self.currentSelf
                                          anchor:canchor
                                            slot:cslot.unsignedIntegerValue
                                       argValues:[margs subarrayWithRange:NSMakeRange(1, margs.count - 1)]
                                      resultType:mResult];
                    }
                NSNumber* vslot = selfCi.methodSlot[methodMangled]
                                      ?: ci.methodSlot[methodMangled];
                if (vslot)
                    {
                    return [self emitVTblDispatch:self.currentSelf
                                             slot:vslot.unsignedIntegerValue
                                        argValues:[margs subarrayWithRange:NSMakeRange(1, margs.count - 1)]
                                       resultType:mResult];
                    }
                }
            XTIRCallConv* mconv =
                msym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                : msym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                       : [XTIRCallConv standard];
            XTIRSymbolId mid = [self.module.symbols indexOfObjectIdenticalTo:msym];
            return [self emitCall:mid
                         callConv:mconv
                        argValues:margs
                       resultType:mResult];
            }
        }
    // `use Klass;` directive: sema stamped resolvedClassName on a bare
    // call like `printf(...)` after `use Stdio;`. Look the method up as
    // `<class>$<mangled>` and emit it as a static-method call — the same
    // shape lowerMethodCallExpr produces for `Stdio.printf(...)`, including
    // the static-init guard (otherwise `__sdata.canPrint` stays zero and
    // printf silently no-ops on xt6502), arg coercion, and varargs packing.
    if (!sym && node.resolvedClassName.length > 0 && node.resolvedMangledName.length > 0)
        {
        NSString* useSymName = [NSString stringWithFormat:@"%@$%@",
                                                          node.resolvedClassName, node.resolvedMangledName];
        XTIRSymbol* usym = [self.module symbolForName:useSymName];
        if (usym)
            {
            BOOL useStatic = usym.attributes[@"static"].boolValue;
            XTIRClassInfo* useCi = self.classesByName[node.resolvedClassName];
            if (useStatic && useCi)
                {
                // Run `init` once on the class's `__sdata` block — same as
                // lowerMethodCallExpr's static path; otherwise `canPrint`
                // etc. read zero on first call.
                [self emitStaticInitGuardForClass:useCi];
                }
            NSMutableArray<XTIRValue*>* uargs = [NSMutableArray array];
            for (XTASTNode* a in node.arguments)
                {
                XTIRValue* av = [self lowerExpression:a];
                if (!av)
                    return nil;
                [uargs addObject:av];
                }
            // Coerce each fixed arg to the callee's matching param type.
            // (`uargs` excludes self; static methods have no self slot in
            // the symbol's paramTypes either, so selfOff is always 0.)
            if (usym.function)
                {
                NSUInteger nParam = usym.function.paramTypes.count; // fixed + Mem
                for (NSUInteger i = 0; i < uargs.count && i < node.arguments.count; i++)
                    {
                    if (i + 1 >= nParam)
                        break; // reached Memory token / varargs
                    XTIRType* dstIR = usym.function.paramTypes[i];
                    XTType* srcAST = [node.arguments[i] resolvedType];
                    if (!srcAST || dstIR.kind == XTIRTypeKindVoid || dstIR.kind == XTIRTypeKindPtr)
                        continue;
                    // NEVER integer-extend an aggregate. A `^` parameter is an Agg, and this
                    // loop would otherwise emit `ZExt %agg` from the ARGUMENT's pointer width.
                    // An fn-pointer arg here is a `@`->`^` widening; any other aggregate is
                    // already the value the callee wants.
                    if (dstIR.kind == XTIRTypeKindAgg)
                        {
                        [self widenBoundArgAt:i in:uargs ofASTType:srcAST toAgg:dstIR];
                        continue;
                        }
                    NSUInteger srcW = srcAST.byteWidth, dstW = dstIR.byteWidth;
                    BOOL srcSgn = srcAST.isSigned, dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                    if (srcW == dstW && srcSgn == dstSgn)
                        continue;
                    XTIROpcode op = dstW > srcW   ? (srcSgn ? XTIROpSExt : XTIROpZExt)
                                    : dstW < srcW ? XTIROpTrunc
                                                  : XTIROpBitcast;
                    XTIRValue* cv = [self emitInsnOpcode:op
                                                  result:dstIR
                                                operands:@[ [XTIROperand useWithValueId:((XTIRValue*)uargs[i]).valueId] ]];
                    if (cv)
                        uargs[i] = cv;
                    }
                }
            // Variadic packing — printf, et al. Drop the trailing Memory
            // token from the fixed-param count; static methods have no
            // self slot, so no further subtraction. Same convention gate as
            // the direct-method and free-function paths: a C-ABI import or a
            // native-va_list target (arm9) passes AAPCS-promoted args — this
            // path packed UNCONDITIONALLY, so a use-promoted `printf` on
            // arm9 wrote __xtc_va_buf while the callee read its registers.
            NSArray<XTIRValue*>* upassArgs = uargs;
            if (usym.attributes[@"variadic"].boolValue && usym.function)
                {
                NSInteger fc = (NSInteger)usym.function.paramTypes.count - 1;
                if (!useStatic)
                    fc -= 1; // drop self for instance method
                NSUInteger fcu = fc > 0 ? (NSUInteger)fc : 0;
                upassArgs = (usym.attributes[@"cabi"].boolValue || self.nativeVarargs)
                                ? [self cVarargPromote:uargs fixedCount:fcu]
                                : [self packVarargsFrom:uargs fixedCount:fcu];
                }
            NSMutableArray<XTIRValue*>* ucallArgs = [NSMutableArray array];
            if (!useStatic && self.currentSelf)
                {
                [ucallArgs addObject:self.currentSelf]; // very unusual for use-call
                }
            [ucallArgs addObjectsFromArray:upassArgs];
            XTIRType* uResult = nil;
            if (node.resolvedType && !node.resolvedType.isVoid)
                {
                uResult = [self irTypeForASTType:node.resolvedType at:node.location];
                if (!uResult)
                    return nil;
                }
            XTIRCallConv* uconv =
                usym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                : usym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                       : [XTIRCallConv standard];
            XTIRSymbolId uid = [self.module.symbols indexOfObjectIdenticalTo:usym];
            return [self emitCall:uid
                         callConv:uconv
                        argValues:ucallArgs
                       resultType:uResult];
            }
        }
    if (!sym)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: call to unknown function '%@'", node.calleeName]];
        return nil;
        }
    XTIRFunction* calleeFn = sym.function;
    NSMutableArray<XTIRValue*>* args = [NSMutableArray array];
    for (NSUInteger i = 0; i < node.arguments.count; i++)
        {
        XTASTNode* a = node.arguments[i];
        XTIRValue* av = [self lowerExpression:a];
        if (!av)
            return nil;
        // Coerce arg type to match callee's i-th param. (paramTypes
        // ends with Mem; user-visible params are at indices 0..N-2.)
        if (calleeFn && i < calleeFn.paramTypes.count - 1)
            {
            XTIRType* dstIR = calleeFn.paramTypes[i];
            // By-value struct arg from an lvalue (e.g. a global `g`):
            // lowerExpression gave its ADDRESS (Ptr(Agg)), but the param is
            // the Agg by value. Load the aggregate so we pass the VALUE — the
            // same form a struct rvalue arg already takes, which both backends
            // marshal correctly. Without this the callee receives the pointer
            // bytes as the struct and reads garbage.
            // `@`->`^` widening: a function pointer passed where a bound method
            // is expected (`setAction(&freeFunc)`). MUST be tested BEFORE the
            // struct-lvalue load below — that path treats a Ptr arg for an Agg
            // param as the ADDRESS of a struct and dereferences it, which for a
            // function pointer reads the callee's CODE bytes as a struct. (It
            // segfaulted.)
            BOOL widened = NO;
            if (dstIR.kind == XTIRTypeKindAgg)
                {
                XTFunctionType* wsig = [self fnSignatureForWidening:a.resolvedType];
                if (wsig)
                    {
                    XTIRValue* w = [self widenFunctionPointer:av
                                                    signature:wsig
                                                    toAggType:dstIR];
                    if (w)
                        {
                        av = w;
                        widened = YES;
                        }
                    }
                }
            if (!widened && dstIR.kind == XTIRTypeKindAgg && av.type && av.type.kind == XTIRTypeKindPtr)
                {
                av = [self emitLoad:av pointeeType:dstIR];
                if (!av)
                    return nil;
                }
            XTType* srcAST = a.resolvedType;
            // Only integer/sign width-adjust scalar args. A pointer arg
            // (e.g. a function pointer passed to a `FuncType@` parameter,
            // or any `T@`) must pass through untouched — applying the
            // integer SExt/ZExt/Trunc path to a pointer would corrupt the
            // address (it Trunc'd function pointers, crashing indirect
            // dispatch). Pointer↔pointer needs no coercion here.
            // A widened `^` is already the exact Agg the callee wants. Its AST
            // type is still the FUNCTION POINTER, so the integer width-adjust
            // below would compare a pointer's width against the aggregate's and
            // emit `ZExt %agg` — an integer extend on a struct.
            if (srcAST && !widened && dstIR.kind != XTIRTypeKindVoid && dstIR.kind != XTIRTypeKindPtr)
                {
                BOOL srcFlt = av.type && XTIRTypeKindIsFloating(av.type.kind);
                BOOL dstFlt = XTIRTypeKindIsFloating(dstIR.kind);
                if (srcFlt || dstFlt)
                    {
                    // int↔float / float↔float at the call boundary. Without
                    // this an int arg to a float param was zero-/sign-extended
                    // as raw bits (the int-only path below), so the callee saw
                    // the integer's bit pattern instead of its float value —
                    // e.g. fadd(6.0, (u16)3) passed 3, not 3.0.
                    XTIROpcode fop = 0;
                    BOOL emit = YES;
                    if (srcFlt && dstFlt)
                        {
                        if (av.type.byteWidth == dstIR.byteWidth)
                            emit = NO;
                        else
                            fop = (dstIR.byteWidth > av.type.byteWidth)
                                      ? XTIROpFpExt
                                      : XTIROpFpTrunc;
                        }
                    else if (dstFlt)
                        {
                        fop = XTIRTypeKindIsSigned(av.type.kind)
                                  ? XTIROpSIToFp
                                  : XTIROpUIToFp;
                        }
                    else
                        {
                        fop = XTIRTypeKindIsSigned(dstIR.kind)
                                  ? XTIROpFpToSI
                                  : XTIROpFpToUI;
                        }
                    if (emit)
                        {
                        av = [self emitInsnOpcode:fop
                                           result:dstIR
                                         operands:@[ [XTIROperand useWithValueId:av.valueId] ]];
                        if (!av)
                            return nil;
                        }
                    }
                else
                    {
                    NSUInteger srcW = srcAST.byteWidth;
                    NSUInteger dstW = dstIR.byteWidth;
                    BOOL srcSgn = srcAST.isSigned;
                    BOOL dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                    if (srcW != dstW || srcSgn != dstSgn)
                        {
                        XTIROpcode op;
                        if (dstW > srcW)
                            op = srcSgn ? XTIROpSExt : XTIROpZExt;
                        else if (dstW < srcW)
                            op = XTIROpTrunc;
                        else
                            op = XTIROpBitcast;
                        av = [self emitInsnOpcode:op
                                           result:dstIR
                                         operands:@[ [XTIROperand useWithValueId:av.valueId] ]];
                        if (!av)
                            return nil;
                        }
                    }
                }
            }
        [args addObject:av];
        }
    XTIRType* resultIR = nil;
    if (node.resolvedType && !node.resolvedType.isVoid)
        {
        resultIR = [self irTypeForASTType:node.resolvedType at:node.location];
        if (!resultIR)
            return nil;
        }
    XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];
    // Variadic free function (`void checker(string tag, ...)`): pack
    // the args past the fixed prefix into `__xtc_va_buf`. The method-
    // call path does the same at line 3137; this is the free-function
    // analog for user-declared variadic functions (printf-style libs
    // already had this through the Stdio.* method path). Without it,
    // every vararg goes through the hw stack as a positional arg the
    // callee can't read with `va_arg_*` (which reads the buffer
    // directly), so all 10 valist tests came back zero. `paramTypes`
    // includes the trailing Memory token, so the fixed-user-param
    // count is `count - 1`.
    NSArray<XTIRValue*>* callArgs = args;
    if (sym.attributes[@"variadic"].boolValue && sym.function)
        {
        NSInteger fc = (NSInteger)sym.function.paramTypes.count - 1;
        NSUInteger fcu = fc > 0 ? (NSUInteger)fc : 0;
        callArgs = (sym.attributes[@"cabi"].boolValue || self.nativeVarargs) // C import (printf) or native-va_list target (arm9)
                       ? [self cVarargPromote:args fixedCount:fcu]
                       : [self packVarargsFrom:args fixedCount:fcu];
        }
    return [self emitCall:sid
                 callConv:[XTIRCallConv standard]
                argValues:callArgs
               resultType:resultIR];
    }

#pragma mark - Statement dispatch

- (void)lowerStatement:(XTASTNode*)node
    {
    if (self.aborted)
        return;
    // Statement boundary: each full-expression statement (expr-stmt /
    // var-decl / return) flushes its own +1 owned temps at its end, so
    // ownedTemps is normally empty here. Anything left is a straggler from
    // a non-flushing boundary (an if/while/for CONDITION, which rarely
    // produces a class temp) — drop it untracked rather than let it bleed
    // into and be wrongly released by a later statement (#123). A dropped
    // temp leaks, the safe pre-#123 default.
    [self.ownedTemps removeAllObjects];
    [self.ownedTempDepths removeAllObjects];
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        [self lowerBlockStmt:(XTBlockNode*)node];
        break;
    case XTASTNodeKindVariableDecl:
        [self lowerVarDecl:(XTVariableDeclNode*)node];
        break;
    case XTASTNodeKindReturn:
        [self lowerReturnStmt:(XTReturnNode*)node];
        break;
    case XTASTNodeKindIf:
        [self lowerIfStmt:(XTIfNode*)node];
        break;
    case XTASTNodeKindWhile:
        [self lowerWhileStmt:(XTWhileNode*)node];
        break;
    case XTASTNodeKindExprStatement:
        [self lowerExprStmt:(XTExpressionStatementNode*)node];
        break;
    case XTASTNodeKindDelete:
        [self lowerDeleteStmt:(XTDeleteNode*)node];
        break;
    case XTASTNodeKindAsmBlock:
        [self lowerAsmBlock:(XTAsmBlockNode*)node];
        break;
    case XTASTNodeKindForCStyle:
        [self lowerForCStyleStmt:(XTForCStyleNode*)node];
        break;
    case XTASTNodeKindForIn:
        [self lowerForInStmt:(XTForInNode*)node];
        break;
    case XTASTNodeKindBreak:
        [self lowerBreakStmt:(XTBreakNode*)node];
        break;
    case XTASTNodeKindContinue:
        [self lowerContinueStmt:(XTContinueNode*)node];
        break;
    case XTASTNodeKindGoto:
        [self lowerGotoStmt:(XTGotoNode*)node];
        break;
    case XTASTNodeKindLabel:
        [self lowerLabelStmt:(XTLabelNode*)node];
        break;
    case XTASTNodeKindDefer:
        [self lowerDeferStmt:(XTDeferNode*)node];
        break;
    case XTASTNodeKindThrow:
        [self lowerThrowStmt:(XTThrowNode*)node];
        break;
    case XTASTNodeKindTry:
        [self lowerTryStmt:(XTTryNode*)node];
        break;
    case XTASTNodeKindTupleAssign:
        [self lowerTupleAssignStmt:(XTTupleAssignNode*)node];
        break;
    case XTASTNodeKindTypedefDecl:
        break; // no-op: type alias, no runtime effect
    case XTASTNodeKindSwitch:
        [self lowerSwitchStmt:(XTSwitchNode*)node];
        break;
    default:
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: unsupported statement kind %ld", (long)node.nodeKind]];
        }
    }

- (void)lowerDeleteStmt:(XTDeleteNode*)node
    {
    XTIRValue* v = [self lowerExpression:node.operand];
    if (!v)
        return;
    switch (node.op)
        {
    case XTRefOpRetain:
        [self emitRetain:v];
        break;
    case XTRefOpDelete:
    case XTRefOpRelease:
        [self emitRelease:v];
        break;
        }
    // `delete <local>` (manual lifecycle, -farc=off) transfers ownership out of the
    // scope: the object is released HERE. Untrack the local so the scope-exit
    // teardown doesn't release it a SECOND time — a use-after-free / double-free
    // that only stays hidden on backends whose freed memory happens to remain
    // mapped. A conditional `delete` untracks unconditionally, so the un-deleted
    // path leaks rather than double-frees — the safe side.
    if (node.op == XTRefOpDelete && node.operand.nodeKind == XTASTNodeKindIdentifier)
        {
        [self untrackOwnedLocalNamed:((XTIdentifierNode*)node.operand).identName];
        }
    }

// Remove a local from every ARC scope-exit teardown structure — used when a
// `delete` has already released it (see lowerDeleteStmt).
- (void)untrackOwnedLocalNamed:(NSString*)name
    {
    if (!name)
        return;
    for (NSMutableArray<NSString*>* scope in self.arcScopeStack)
        [scope removeObject:name];
    [self.strongLocals removeObject:name];
    [self.strongArrayLocals removeObjectForKey:name];
    [self.weakArrayLocals removeObjectForKey:name];
    [self.strongStructLocals removeObjectForKey:name];
    [self.strongStructArrayLocals removeObjectForKey:name];
    }

#pragma mark - Tuple assignment (multi-return destructuring)

- (void)lowerTupleAssignStmt:(XTTupleAssignNode*)node
    {
    // `(x, y) = makePair(...)` — the source expression is a call that
    // returns an aggregate (Agg) type. Lower the call manually so we
    // can capture the aggregate result, then AggExtract each field
    // into the corresponding target variable.
    XTASTNode* src = node.sourceExpr;

    // Resolve the callee's function symbol to get the aggregate return
    // type. The source must be a call expression.
    NSString* calleeName = nil;
    NSArray<XTASTNode*>* callArgs = nil;
    XTIRType* aggRetType = nil;

    if (src.nodeKind == XTASTNodeKindCallExpr)
        {
        XTCallExprNode* call = (XTCallExprNode*)src;
        calleeName = call.resolvedMangledName ?: call.calleeName;
        callArgs = call.arguments;
        // Look up the function symbol to get its aggregate return type.
        XTIRSymbol* sym = [self.module symbolForName:calleeName];
        if (!sym)
            sym = [self.module symbolForName:call.calleeName];
        if (sym && sym.function)
            {
            aggRetType = sym.function.returnType;
            }
        }
    else if (src.nodeKind == XTASTNodeKindMethodCallExpr)
        {
        XTMethodCallExprNode* mcall = (XTMethodCallExprNode*)src;
        calleeName = mcall.resolvedMangledName ?: mcall.methodName;
        callArgs = mcall.arguments;
        // Method calls: resolve the method symbol through the class.
        // (Multi-return method calls not yet supported on this path.)
        [self softFailLoweringAt:src.location
                     withMessage:@"lowering: multi-return method call not yet supported"];
        return;
        }

    if (!aggRetType || aggRetType.kind != XTIRTypeKindAgg)
        {
        [self softFailLoweringAt:src.location
                     withMessage:@"lowering: tuple assign source does not return an aggregate"];
        return;
        }

    // Lower the call arguments first.
    NSMutableArray<XTIRValue*>* loweredArgs = [NSMutableArray array];
    XTIRSymbol* calleeSym = [self.module symbolForName:calleeName];
    if (!calleeSym)
        {
        [self softFailLoweringAt:src.location
                     withMessage:[NSString stringWithFormat:
                                               @"lowering: call to unknown function '%@'", calleeName]];
        return;
        }

    for (XTASTNode* arg in callArgs)
        {
        XTIRValue* av = [self lowerExpression:arg];
        if (!av)
            return;
        [loweredArgs addObject:av];
        }

    // Emit the call with the aggregate result type.
    XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:calleeSym];
    XTIRValue* aggResult = [self emitCall:sid
                                 callConv:[XTIRCallConv standard]
                                argValues:loweredArgs
                               resultType:aggRetType];
    if (!aggResult)
        return;

    // Extract each field and assign to the corresponding target.
    XTIRLayout* layout = aggRetType.layout;
    for (NSUInteger i = 0; i < node.targets.count && i < layout.fields.count; i++)
        {
        XTASTNode* target = node.targets[i];
        XTIRType* fieldIR = layout.fields[i].type;

        // Emit AggExtract for field i.
        XTIRValue* fieldVal = [self allocateValueOfType:fieldIR atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpAggExtract
                                                         result:fieldVal
                                                       operands:@[ [XTIROperand useWithValueId:aggResult.valueId],
                                                                   [XTIROperand immIWithType:[XTIRType u16Type]
                                                                                       value:(int64_t)i] ]
                                                         dbgLoc:nil]];

        // Assign the extracted value to the target.
        // The values come from a multi-return CALL, so they are +1
        // references (ownership transferred). No retain needed.
        if ([target isKindOfClass:[XTVariableDeclNode class]])
            {
            XTVariableDeclNode* vd = (XTVariableDeclNode*)target;
            // Declare the variable (no initialiser — we have the value).
            vd.initialiser = nil;
            [self lowerVarDecl:vd];
            self.locals[vd.varName] = fieldVal;
            }
        else if (target.nodeKind == XTASTNodeKindIdentifier)
            {
            XTIdentifierNode* idn = (XTIdentifierNode*)target;
            XTIRValue* existing = self.locals[idn.identName];
            if (!existing)
                {
                // An address-taken (`&v`) local lives in a frame slot, not the
                // SSA `locals` map — store the extracted field to its slot, the
                // same way a plain assignment does (bug: fuzz seed 5086, all
                // backends failed "tuple target not found" for `(a,v)=f(v)` with
                // `&v` earlier).
                XTIRPinnedLocal* pl = self.pinnedLocals[idn.identName];
                if (pl)
                    {
                    XTIRType* pptrTy = nil;
                    XTIRValue* addr = [self pinnedAddr:pl name:idn.identName outType:&pptrTy];
                    if (addr)
                        {
                        if ([self.strongLocals containsObject:idn.identName])
                            {
                            // Release the slot's old strong pointer; the call
                            // result is already +1 (ownership transferred).
                            XTIRValue* oldV = [self emitLoad:addr pointeeType:pptrTy];
                            [self emitRelease:oldV];
                            }
                        [self emitStore:addr value:fieldVal];
                        }
                    continue;
                    }
                [self softFailLoweringAt:node.location
                             withMessage:[NSString stringWithFormat:
                                                       @"lowering: tuple target '%@' not found", idn.identName]];
                return;
                }
            // ARC: if the target holds a strong pointer, release the OLD
            // value before overwriting (the call result is already +1).
            if ([self.strongLocals containsObject:idn.identName])
                {
                [self emitRelease:existing];
                // The target stays in strongLocals — the new value is
                // also owned (from the call's +1 transfer).
                }
            self.locals[idn.identName] = fieldVal;
            }
        }
    }

#pragma mark - Inline asm

// Lower an asm block into an XTIROpAsm instruction. The opcode
// captures the raw text via a constant-pool entry; the memory
// token is threaded through so loads/stores around the block
// stay properly ordered. Clobber bitmask + sym-binding resolution
// are out of scope for this task — the existing AST node only
// carries text and a per-block clobber annotation, which we
// stash as an integer immediate operand for the backends.
- (void)lowerAsmBlock:(XTAsmBlockNode*)node
    {
    NSString* joined = [node.lines componentsJoinedByString:@"\n"];
    // Bind inline-asm references to xtc locals: rewrite each whole-word
    // identifier that names a pinned local into a `{{XTLOCAL:<vid>}}`
    // token. The backend substitutes the local's resolved storage
    // address (a ZP byte on xt6502), so `STA scrMode` reaches the local's
    // slot instead of leaking as an undefined symbol → $0000. Only pinned
    // locals are rewritten; opcodes / labels / `$hex` pass through. (The
    // pre-scan pinned every asm-named local — see collectAddressTakenIn.)
    if (self.pinnedLocals.count > 0 || self.currentSelf || self.classesByName.count > 0)
        {
        NSMutableString* rewritten = [NSMutableString string];
        NSUInteger n = joined.length, i = 0;
        while (i < n)
            {
            unichar c = [joined characterAtIndex:i];
            if (c == ';')
                {
                // Comment to end of line — copy verbatim, no rewriting.
                while (i < n)
                    {
                    unichar d = [joined characterAtIndex:i];
                    [rewritten appendFormat:@"%C", d];
                    i++;
                    if (d == '\n')
                        break;
                    }
                continue;
                }
            if (isalpha((int)c) || c == '_')
                {
                NSUInteger start = i;
                while (i < n)
                    {
                    unichar d = [joined characterAtIndex:i];
                    if (isalnum((int)d) || d == '_')
                        i++;
                    else
                        break;
                    }
                NSString* ident = [joined substringWithRange:NSMakeRange(start, i - start)];
                XTIRPinnedLocal* pl = self.pinnedLocals[ident];
                // A bare ivar name of a STATIC utility class (its methods
                // reach fields through the `__sdata_<Class>` block) — e.g.
                // the Atari Math PRNG's `LDA seedLo`. Without binding, the
                // name leaks as an undefined symbol → $0000 (collapsing the
                // PRNG state). Rewrite to a {{XTIVAR:<symId>:<byteOff>}}
                // token the backend resolves to `__sdata_<Class>+byteOff`.
                NSNumber* ivarIdx = nil;
                if (!pl && self.staticSelfClassName && self.currentClassInfo && self.currentClassInfo.instanceLayout)
                    {
                    ivarIdx = self.currentClassInfo.ivarFieldIndex[ident];
                    }
                // `_ivar_<C>_<F>` / `_sizeof_<C>` cross-class equates —
                // an inline-asm site can reference the layout of any
                // class (not just the currently-lowering one's ivars).
                // Resolve to the literal byte-offset / size by walking
                // the classes map; the prefix uniquely identifies which
                // bucket the rest of the ident decodes against. Used
                // primarily by the Atari Stdio %f/%d test scaffolding
                // (printf_float, printf_double) which reads screen RAM
                // via `LDA __sdata_Stdio + _ivar_Stdio_screenBase`.
                NSString* classEquate = nil;
                int classEquateValue = -1;
                if (!pl && !ivarIdx && [ident hasPrefix:@"_sizeof_"])
                    {
                    NSString* cn = [ident substringFromIndex:[@"_sizeof_" length]];
                    XTIRClassInfo* ci = self.classesByName[cn];
                    if (ci && ci.instanceLayout)
                        {
                        classEquate = ident;
                        classEquateValue = (int)ci.instanceLayout.size;
                        }
                    }
                if (!pl && !ivarIdx && !classEquate && [ident hasPrefix:@"_ivar_"])
                    {
                    NSString* rest = [ident substringFromIndex:[@"_ivar_" length]];
                    // Class name extends to the LAST '_' so a field with
                    // underscores parses correctly when the class name is
                    // a plain camelCase identifier (the common case).
                    NSRange sep = [rest rangeOfString:@"_" options:NSBackwardsSearch];
                    while (sep.location != NSNotFound)
                        {
                        NSString* cn = [rest substringToIndex:sep.location];
                        NSString* fn = [rest substringFromIndex:sep.location + 1];
                        XTIRClassInfo* ci = self.classesByName[cn];
                        NSNumber* idxN = ci.ivarFieldIndex[fn];
                        if (ci && idxN && idxN.unsignedIntegerValue < ci.instanceLayout.fields.count)
                            {
                            classEquate = ident;
                            classEquateValue = (int)ci.instanceLayout
                                                   .fields[idxN.unsignedIntegerValue]
                                                   .byteOffset;
                            break;
                            }
                        if (sep.location == 0)
                            break;
                        sep = [rest rangeOfString:@"_"
                                          options:NSBackwardsSearch
                                            range:NSMakeRange(0, sep.location)];
                        }
                    }
                if ([ident isEqualToString:@"__self"] && self.currentSelf)
                    {
                    // Codegen-reserved name for the receiver pointer: the
                    // old AST codegen staged `self` into a fixed `__self`
                    // ZP pair so inline asm could `(__self),Y`. Bind it to
                    // the current-self value (backend ZP-pins it, so the
                    // indirect addressing has a real ZP pointer).
                    [rewritten appendFormat:@"{{XTLOCAL:%lu}}", (unsigned long)self.currentSelf.valueId];
                    }
                else if (pl)
                    {
                    // Byte-extraction operators (`<` lo, `>` hi, `>>` byte2,
                    // `>>>` byte3 — optionally `#`-prefixed) right before a
                    // local select ONE byte of the local's value. The bytes
                    // are stored consecutively in the local's ZP slot, so we
                    // strip the operator (and any `#` immediate marker) and
                    // emit a byte-indexed token the backend resolves to
                    // `$slot + byte`. Leaving `#<{{XTLOCAL}}` would assemble
                    // to `LDA #<$9A` — the immediate low byte of the slot
                    // ADDRESS, not the value (private:docs/bugs/010 #3).
                    // Inspect the suffix for a byte-extraction operator,
                    // ignoring the whitespace the tokeniser inserts between
                    // the operator and the name (`#< val`). Critically this
                    // is NON-destructive unless an operator is actually
                    // found — otherwise a plain `LDA val` would lose the
                    // space before its token (`LDA{{XTLOCAL}}` → invalid),
                    // which silently broke every asm block (printf et al.).
                    NSCharacterSet* ws = [NSCharacterSet whitespaceCharacterSet];
                    NSUInteger end = 0;
                    int byteSel = -1;
                    NSUInteger opLen = 0;
                    // Only a SCALAR pinned local reads a byte from its ZP
                    // slot. An ARRAY local decays to its ADDRESS, so `<buf`
                    // / `>buf` are the lo/hi byte of buf's ADDRESS — the
                    // standard `#<symbol` immediate, which the plain
                    // {{XTLOCAL}} token already produces. Treating an array
                    // like a scalar broke `(_ptr),Y` pointer setup (the
                    // pointer got buf[0..1] instead of &buf — asm_zp_pressure).
                    if (![self.arrayLocalNames containsObject:ident])
                        {
                        end = rewritten.length;
                        while (end > 0 && [ws characterIsMember:[rewritten characterAtIndex:end - 1]])
                            end--;
                        if (end >= 3 && [[rewritten substringWithRange:NSMakeRange(end - 3, 3)] isEqualToString:@">>>"])
                            {
                            byteSel = 3;
                            opLen = 3;
                            }
                        else if (end >= 2 && [[rewritten substringWithRange:NSMakeRange(end - 2, 2)] isEqualToString:@">>"])
                            {
                            byteSel = 2;
                            opLen = 2;
                            }
                        else if (end >= 1 && [rewritten characterAtIndex:end - 1] == '>')
                            {
                            byteSel = 1;
                            opLen = 1;
                            }
                        else if (end >= 1 && [rewritten characterAtIndex:end - 1] == '<')
                            {
                            byteSel = 0;
                            opLen = 1;
                            }
                        }
                    if (byteSel >= 0)
                        {
                        // Drop the operator (and trailing whitespace) and a
                        // preceding `#` immediate marker, then re-separate.
                        NSUInteger delStart = end - opLen;
                        [rewritten deleteCharactersInRange:NSMakeRange(delStart, rewritten.length - delStart)];
                        if ([rewritten hasSuffix:@"#"])
                            [rewritten deleteCharactersInRange:NSMakeRange(rewritten.length - 1, 1)];
                        if (rewritten.length > 0 && ![ws characterIsMember:[rewritten characterAtIndex:rewritten.length - 1]])
                            [rewritten appendString:@" "];
                        [rewritten appendFormat:@"{{XTLOCALB:%lu:%d}}",
                                                (unsigned long)pl.valueId, byteSel];
                        }
                    else
                        {
                        [rewritten appendFormat:@"{{XTLOCAL:%lu}}", (unsigned long)pl.valueId];
                        }
                    }
                else if (ivarIdx && ivarIdx.unsignedIntegerValue < self.currentClassInfo.instanceLayout.fields.count)
                    {
                    uint32_t byteOff = self.currentClassInfo.instanceLayout
                                           .fields[ivarIdx.unsignedIntegerValue]
                                           .byteOffset;
                    XTIRSymbolId sid = [self staticDataSymbolForClass:self.currentClassInfo];
                    [rewritten appendFormat:@"{{XTIVAR:%lu:%u}}",
                                            (unsigned long)sid, byteOff];
                    }
                else if (classEquate)
                    {
                    [rewritten appendFormat:@"%d", classEquateValue];
                    }
                else
                    {
                    [rewritten appendString:ident];
                    }
                }
            else
                {
                [rewritten appendFormat:@"%C", c];
                i++;
                }
            }
        joined = rewritten;
        }
    NSData* textData = [joined dataUsingEncoding:NSUTF8StringEncoding];
    XTIRConstant* textConst = [XTIRConstant stringConstantWithBytes:textData];
    XTIRConstantId cid = [self.module addConstant:textConst];
    XTIRValue* newMem = [self allocateValueOfType:[XTIRType memoryType]
                                           atSite:self.currentBlock];
    NSArray<XTIROperand*>* operands = @[
        [XTIROperand constAggWithConstantId:cid],
        [XTIROperand immIWithType:[XTIRType i16Type]
                            value:node.userClobbers],
        [XTIROperand useWithValueId:self.memToken.valueId],
    ];
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpAsm
                                               result:nil
                                             operands:operands
                                               dbgLoc:nil];
    insn.memoryResult = newMem;
    [self.currentBlock appendInstruction:insn];
    self.memToken = newMem;
    }

#pragma mark - C-style for loop

- (void)lowerForCStyleStmt:(XTForCStyleNode*)node
    {
    // The whole statement gets its own scope frame: the init variable's
    // SCOPE is the for statement (so `for (u32 t ...)` after a `String* t`
    // shadows it only for the loop — finding #16), and a class-pointer
    // init local is released when the loop is left, not at the end of the
    // enclosing block. Pushed BEFORE the loopStack entry records its
    // arcDepth, so break/continue unwind inner scopes only and this
    // frame's releases land once, in the exit block every exit reaches.
    [self pushArcScope];
    // Lower the init in the predecessor block (its locals' writes
    // participate in the header's preheader snapshot). The parser
    // stores it as either a VariableDeclNode (`for (u8 i = 0; ...`)
    // or a bare expression (`for (i = 0; ...`); dispatch by kind.
    if (node.loopInit)
        {
        if (node.loopInit.nodeKind == XTASTNodeKindVariableDecl)
            {
            [self lowerStatement:node.loopInit];
            }
        else
            {
            (void)[self lowerExpression:node.loopInit];
            }
        }
    if (self.aborted)
        {
        [self popArcScopeEmittingReleases:NO];
        return;
        }

    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* headerBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_for_header"]];
    // `for (...) : unroll` — record the HEADER so the IR unroller can raise its
    // budgets for this loop. The annotation used to be parsed, stored on the
    // AST node and read by nothing: forceUnroll was a hook for the AST
    // optimiser, and when that was removed in phase-323 nobody reconnected it
    // to the IR unroller that replaced it. The IR carries no per-loop metadata,
    // so there was nothing obvious to reconnect it TO — hence a name here and a
    // conditional `unroll:` line in the text.
    if (node.forceUnroll && headerBlock.name)
        [self.currentFunction.forcedUnrollHeaders addObject:headerBlock.name];
    XTIRBlock* bodyBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_for_body"]];
    XTIRBlock* exitBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_for_exit"]];

    XTIRBlock* preheader = self.currentBlock;
    XTIRLocalSnapshot* preSnap = [self snapshotLocals];

    [self emitTerminator:XTIROpBranch
                operands:@[ [XTIROperand blockWithRef:headerBlock] ]];

    // Pre-scan the body + increment for assigned locals — same
    // machinery the while-loop lowering uses.
    NSMutableSet<NSString*>* assigned = [NSMutableSet set];
    if (node.body)
        [self collectAssignedLocalsIn:node.body into:assigned];
    if (node.increment)
        [self collectAssignedLocalsIn:node.increment into:assigned];

    NSMutableDictionary<NSString*, XTIRInsn*>* phiByName = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, XTIRValue*>* headerLocals = [NSMutableDictionary dictionary];
    for (NSString* name in preSnap)
        headerLocals[name] = preSnap[name];

    // SORTED, not the set's own order: an NSSet iterates in hash order, which
    // is stable within a build but is not a property of the program. The phi
    // ORDER at a loop header is visible in the IR text, so leaving it to the
    // hash makes the front end's output unpredictable from its input — and
    // unreproducible by any other implementation of the same lowering.
    for (NSString* name in [assigned.allObjects sortedArrayUsingSelector:@selector(compare:)])
        {
        XTIRValue* entryVal = preSnap[name];
        if (!entryVal)
            continue;
        XTIRType* ty = entryVal.type;
        XTIRValueId vid = [self.currentFunction allocateValueId];
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:headerBlock insnIndex:0];
        XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:ty defSite:site];
        [self.currentFunction registerValue:phiResult];
        NSArray<XTIROperand*>* operands = @[
            [XTIROperand blockWithRef:preheader],
            [XTIROperand useWithValueId:entryVal.valueId],
            [XTIROperand blockWithRef:bodyBlock],
            [XTIROperand useWithValueId:entryVal.valueId],
        ];
        XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                  result:phiResult
                                                operands:operands
                                                  dbgLoc:nil];
        [headerBlock.phiNodes addObject:phi];
        phiByName[name] = phi;
        headerLocals[name] = phiResult;
        }

    // Header: evaluate condition (or unconditional Branch if absent).
    self.currentBlock = headerBlock;
    self.locals = headerLocals;
    // The block the CondBranch ends up in is NOT always the header: a
    // short-circuit condition (`i < n && d > 0`) lowers into extra blocks, and
    // the branch is emitted in the last of them. That block — not the header —
    // is the exit's predecessor, and an exit phi that says otherwise is
    // rejected by the verifier (§12.4 pred/phi mismatch). See lowerWhileStmt.
    XTIRBlock* condExit = headerBlock;
    if (node.condition)
        {
        XTIRBlock* condStart = self.currentBlock;
        XTIRValue* cond = [self lowerConditionExpr:node.condition];
        if (!cond)
            {
            [self popArcScopeEmittingReleases:NO];
            return;
            }
        // A CONDITION is a full expression, so any +1 temporary it produced is
        // released here — before the branch, on the single path where it was
        // created. Nothing did this, so `if (list.get(0) != 0)` leaked the object
        // it tested: harmless while a +0 convention meant conditions rarely held a
        // +1, and a leak per test the moment every class-pointer return became +1.
        [self flushOwnedTempsFrom:condStart];
        condExit = self.currentBlock;
        [self emitTerminator:XTIROpCondBranch
                    operands:@[ [XTIROperand useWithValueId:cond.valueId],
                                [XTIROperand blockWithRef:bodyBlock],
                                [XTIROperand blockWithRef:exitBlock] ]];
        }
    else
        {
        [self emitTerminator:XTIROpBranch
                    operands:@[ [XTIROperand blockWithRef:bodyBlock] ]];
        }

    // Body. break → exit; continue runs the increment then → header.
    // The frame carries the increment expression (so continue can
    // re-run it) and a "continues" bucket so each continue edge gets a
    // matching header-phi operand.
    NSMutableArray* continues = [NSMutableArray array];
    NSMutableArray* breaks = [NSMutableArray array];
    [self.loopStack addObject:@{@"header" : headerBlock,
                                @"arcDepth" : @(self.arcScopeStack.count),
                                @"exit" : exitBlock,
                                @"continues" : continues,
                                @"breaks" : breaks,
                                @"increment" : node.increment ?: [NSNull null]}];

    self.currentBlock = bodyBlock;
    self.locals = [headerLocals mutableCopy];
    if (node.body)
        [self lowerStatement:node.body];
    if (self.aborted)
        {
        [self.loopStack removeLastObject];
        [self popArcScopeEmittingReleases:NO];
        return;
        }
    if (!self.currentBlock.terminator && node.increment)
        {
        // The parser stores increment as a bare expression (not an
        // ExprStatement), so route through lowerExpression. Discard
        // the result — the increment is evaluated for its side
        // effects (typically a postfix or compound assignment).
        (void)[self lowerExpression:node.increment];
        if (self.aborted)
            {
            [self.loopStack removeLastObject];
            [self popArcScopeEmittingReleases:NO];
            return;
            }
        }
    XTIRBlock* bodyExit = self.currentBlock;
    // The body falls through to the header (via its increment) only if
    // it didn't already self-terminate. A self-terminated bodyExit is
    // a recorded continue (→ header, after its own increment) or a
    // break (→ exit), so it must not also count as the fall-through.
    BOOL bodyFellThrough = (bodyExit.terminator == nil);
    if (bodyFellThrough)
        {
        [self emitTerminator:XTIROpBranch
                    operands:@[ [XTIROperand blockWithRef:headerBlock] ]];
        }
    [self.loopStack removeLastObject];

    // Rebuild each header phi: the preheader edge, the fall-through
    // back-edge (post-increment, if the body fell through), and one
    // edge per `continue` (each having already run the increment).
    // Ordered by fn.blocks index (verifier §12.4).
    for (NSString* name in phiByName)
        {
        XTIRInsn* phi = phiByName[name];
        XTIRValue* entryVal = preSnap[name];
        NSMutableArray<NSArray*>* pairs = [NSMutableArray array];
        [pairs addObject:@[ preheader, entryVal ]];
        if (bodyFellThrough)
            {
            [pairs addObject:@[ bodyExit, (self.locals[name] ?: entryVal) ]];
            }
        for (NSDictionary* rec in continues)
            {
            XTIRLocalSnapshot* cl = rec[@"locals"];
            [pairs addObject:@[ rec[@"block"], (cl[name] ?: entryVal) ]];
            }
        [pairs sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) {
          NSUInteger ia = [self.currentFunction.blocks indexOfObjectIdenticalTo:a[0]];
          NSUInteger ib = [self.currentFunction.blocks indexOfObjectIdenticalTo:b[0]];
          return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (NSArray* p in pairs)
            {
            [ops addObject:[XTIROperand blockWithRef:p[0]]];
            [ops addObject:[XTIROperand useWithValueId:((XTIRValue*)p[1]).valueId]];
            }
        [phi setValue:[ops copy] forKey:@"operands"];
        }

    // The header reaches the exit only when the loop has a condition
    // (a bare `for(;;)` branches unconditionally to the body, so its
    // exit is reached solely via breaks).
    self.currentBlock = exitBlock;
    [self bindLoopExitLocalsInBlock:exitBlock
                        headerBlock:condExit
                  headerReachesExit:(node.condition != nil)
                       headerLocals:headerLocals
                             breaks:breaks];
    // Close the statement's own scope: releases an init-declared strong
    // local here in the exit block (reached by fall-out and breaks alike),
    // and restores any binding the init shadowed.
    [self popArcScopeEmittingReleases:YES];
    }

#pragma mark - For-in loop

// Lower `for (T v in collection) { body }`. Supports:
//   - Array lvalue: `for (u8 v in arr)` — uses the array's element
//     count and base address.
//   - Slice expression: `for (u8 v in arr[2..5])` — uses the
//     slice's start/end bounds to derive pointer + count.
//   - Class-instance collections (Enumerable protocol) — not yet
//     implemented (soft-fail).
- (void)lowerForInStmt:(XTForInNode*)node
    {
    // The statement's own scope frame: the loop VARIABLE scopes to the loop
    // (it may shadow an outer local — finding #16), and the retained
    // Enumerable subject temp enrols here so it is released at loop exit.
    // A WRAPPER because the body has a dozen soft-skip early returns, every
    // one of which must still pop the frame.
    if (self.aborted)
        return;
    XTVariableDeclNode* lv = (XTVariableDeclNode*)node.loopVar;
    [self pushArcScope];
    if (lv.varName)
        [self saveShadowedBindingsForName:lv.varName];
    [self lowerForInStmtInner:node];
    [self popArcScopeEmittingReleases:!self.aborted];
    }

- (void)lowerForInStmtInner:(XTForInNode*)node
    {
    if (self.aborted)
        return;

    // Resolve the element type from the loop variable declaration.
    XTVariableDeclNode* loopVar = (XTVariableDeclNode*)node.loopVar;
    XTType* elemAST = loopVar.declaredType;
    XTIRType* elemIR = [self irTypeForASTType:elemAST at:node.location];
    if (!elemIR)
        return;

    XTASTNode* collection = node.collection;
    XTType* collType = collection.resolvedType;

    // ── Derive the element count; defer base-address to body ──
    // (We emit decayArrayBaseToPtr inside the loop body so the
    // array's SSA value stays live across sinit/printf calls,
    // which lets the x6502 codegen's caller-save correctly preserve
    // the array's ZP bytes — see task #92 / bug #003.)
    XTIRValue* countVal = nil; // number of elements

    // Width of the loop counter. u16 for every statically-counted collection
    // (a fixed array, a slice, a `new T[N]` buffer — the count is a compile-
    // time constant and cannot overflow it). An Enumerable class, though,
    // reports its own count at runtime, and the width of THAT is the library's
    // choice: a 32-bit Foundation declares `u32 enumLength()`. Assuming u16
    // here would compare a u32 count against a u16 counter and stop
    // enumerating at 65536 without a word of complaint.
    // The for-in counter is an element COUNT, so it is the count width, not a
    // bare u16 — with `.length` wider than 16 bits, a u16 counter met a wider
    // bound and the slice's `idx + start` adjustment mismatched. The class
    // path below still overrides it from enumLength's declared return type.
    XTIRType* idxIR = [self countIRType];

    // Saved context for the body-block AddrOf / class-enumerable dispatch.
    BOOL isArrayBase = NO;
    BOOL isSliceBase = NO;
    BOOL isClassEnum = NO;
    BOOL isHeapPtrBase = NO;        // direct for-in over a heap pointer (heapArrayLengthByLocal)
    XTASTNode* baseForAddr = nil;   // identifier to pass to decayArrayBaseToPtr (or lowerExpression for heap)
    XTType* sliceBaseAST = nil;     // resolved type of slice base
    XTIRValue* sliceByteOff = nil;  // slice start element index (for index adjustment)
    XTIRValue* classEnumRecv = nil; // class-instance receiver value (for enumAt dispatch)
    NSUInteger classEnumAtSlot = 0; // virtual slot for enumAt

    if (collType && collType.kind == XTTypeKindArray && [collType isKindOfClass:[XTArrayType class]])
        {
        // Array lvalue: `for (T v in arr)`.
        XTArrayType* arrAST = (XTArrayType*)collType;
        if ([collection isKindOfClass:[XTIdentifierNode class]])
            {
            countVal = [self emitInsnOpcode:XTIROpConst
                                     result:[self countIRType]
                                   operands:@[ [XTIROperand immIWithType:[self countIRType]
                                                                   value:(int64_t)arrAST.elementCount] ]];
            isArrayBase = YES;
            baseForAddr = collection;
            }
        else
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: for-in over array requires a simple identifier"];
            return;
            }
        }
    else if (collection.nodeKind == XTASTNodeKindSliceExpr)
        {
        // Slice expression: `for (T v in arr[2..5])`.
        XTSliceExprNode* slice = (XTSliceExprNode*)collection;

        // Analyse the base type (but defer decayArrayBaseToPtr to body).
        sliceBaseAST = slice.base.resolvedType;
        if (!(sliceBaseAST && (sliceBaseAST.kind == XTTypeKindPointer || (sliceBaseAST.kind == XTTypeKindArray && [sliceBaseAST isKindOfClass:[XTArrayType class]]))))
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: for-in slice base must be a pointer or array"];
            return;
            }

        // Compute start index (default 0).
        XTIRValue* startVal = nil;
        if (slice.startExpr)
            {
            startVal = [self lowerExpression:slice.startExpr];
            if (!startVal)
                return;
            if (slice.startExpr.resolvedType &&
                slice.startExpr.resolvedType.byteWidth != [self countASTType].byteWidth)
                {
                startVal = [self coerceValue:startVal
                                    fromType:slice.startExpr.resolvedType
                                      toType:[self countASTType]
                                    location:node.location];
                }
            }
        else
            {
            startVal = [self emitInsnOpcode:XTIROpConst
                                     result:[self countIRType]
                                   operands:@[ [XTIROperand immIWithType:[self countIRType] value:0] ]];
            }

        // Compute end index (default array.length, or error if unknown).
        XTIRValue* endVal = nil;
        if (slice.endExpr)
            {
            endVal = [self lowerExpression:slice.endExpr];
            if (!endVal)
                return;
            if (slice.endExpr.resolvedType &&
                slice.endExpr.resolvedType.byteWidth != [self countASTType].byteWidth)
                {
                endVal = [self coerceValue:endVal
                                  fromType:slice.endExpr.resolvedType
                                    toType:[self countASTType]
                                  location:node.location];
                }
            if (slice.inclusive)
                {
                // Inclusive: add 1 to the end bound so the cmp stays `idx < end`.
                XTIRValue* one = [self emitInsnOpcode:XTIROpConst
                                               result:[self countIRType]
                                             operands:@[ [XTIROperand immIWithType:[self countIRType] value:1] ]];
                endVal = [self emitInsnOpcode:XTIROpAdd
                                       result:[self countIRType]
                                     operands:@[ [XTIROperand useWithValueId:endVal.valueId],
                                                 [XTIROperand useWithValueId:one.valueId] ]];
                }
            }
        else if (sliceBaseAST && sliceBaseAST.kind == XTTypeKindArray && [sliceBaseAST isKindOfClass:[XTArrayType class]])
            {
            endVal = [self emitInsnOpcode:XTIROpConst
                                   result:[self countIRType]
                                 operands:@[ [XTIROperand immIWithType:[self countIRType]
                                                                 value:(int64_t)((XTArrayType*)sliceBaseAST).elementCount] ]];
            }
        else if (sliceBaseAST && sliceBaseAST.kind == XTTypeKindPointer && [slice.base isKindOfClass:[XTIdentifierNode class]] && self.heapArrayLengthByLocal[((XTIdentifierNode*)slice.base).identName])
            {
            // Open-end slice on a heap pointer (`buf[7..]` where
            // `buf = new T[N]`). Use the statically-tracked N as the
            // upper bound — same compile-time value the .length
            // accessor exposes.
            NSNumber* nN = self.heapArrayLengthByLocal[((XTIdentifierNode*)slice.base).identName];
            endVal = [self emitInsnOpcode:XTIROpConst
                                   result:[self countIRType]
                                 operands:@[ [XTIROperand immIWithType:[self countIRType]
                                                                 value:nN.longLongValue] ]];
            }
        else
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: for-in open-ended slice needs a fixed-size array"];
            return;
            }

        // Save startVal as the element-index offset for body-block index
        // adjustment: adjustedIdx = idxB + startVal.
        // count = end - start
        countVal = [self emitInsnOpcode:XTIROpSub
                                 result:[self countIRType]
                               operands:@[ [XTIROperand useWithValueId:endVal.valueId],
                                           [XTIROperand useWithValueId:startVal.valueId] ]];
        isSliceBase = YES;
        sliceByteOff = startVal; // repurposed: "start element index"
        baseForAddr = sliceBaseAST.kind == XTTypeKindPointer ? nil : slice.base;
        }
    else if (collType && collType.kind == XTTypeKindPointer && [(XTPointerType*)collType pointeeType].kind == XTTypeKindClass)
        {
        // Class-instance collection: dispatch through Enumerable protocol's
        // virtual slots — enumLength() for the count, enumAt(i) per element.
        XTType* pointeeType = [(XTPointerType*)collType pointeeType];
        XTIRClassInfo* recvCi = self.classesByName[pointeeType.displayName];
        if (!recvCi)
            {
            [self softFailLoweringAt:node.location
                         withMessage:
                             @"lowering: for-in collection class not found"];
            return;
            }
        NSNumber* lenSlot = recvCi.methodSlot[@"enumLength"];
        NSNumber* atSlot = recvCi.methodSlot[@"enumAt"];
        if (!lenSlot || !atSlot)
            {
            [self softFailLoweringAt:node.location
                         withMessage:
                             @"lowering: class does not implement Enumerable protocol"];
            return;
            }
        // Lower the collection expression to get the receiver value.
        XTIRValue* recvVal = [self lowerExpression:collection];
        if (!recvVal)
            return;
        // Call enumLength() via vtable dispatch to get the element count. Its
        // declared return type sets the loop counter's width — see idxIR.
        XTType* lenRetAST = recvCi.methodReturnAST[@"enumLength"];
        XTIRType* lenIR = lenRetAST ? [self irTypeForASTTypeQuiet:lenRetAST] : nil;
        if (lenIR && XTIRTypeKindIsInteger(lenIR.kind))
            idxIR = lenIR;
        countVal = [self emitVTblDispatch:recvVal
                                     slot:lenSlot.unsignedIntegerValue
                                argValues:@[]
                               resultType:idxIR];
        if (!countVal)
            return;
        // Save context for the body block.
        isClassEnum = YES;
        classEnumRecv = recvVal;
        classEnumAtSlot = atSlot.unsignedIntegerValue;
        // A CALL as the subject hands back a +1 owned temp, and nothing here
        // consumed it — it sat in ownedTemps until the body's first statement
        // boundary dropped it UNTRACKED (lowerStatement's #123 straggler
        // default), so `for (x in makeList())` leaked the list per loop
        // (private:docs/bugs/057). Adopt it exactly as a strong var-decl adopts a +1
        // initialiser: consume the temp and enroll a hidden strong local, so
        // the enclosing scope's pop releases it once on the normal path, an
        // early `return` releases it with every other enrolled local, and a
        // `break` reaches the same pop. An identifier subject is BORROWED
        // (its local owns it), is never in ownedTemps, and takes none of
        // this. Bound BEFORE the pre-loop snapshot below so the name flows
        // into the header and exit locals unchanged — it is never assigned
        // in the body, so it gets no phi.
        if ([self.ownedTemps indexOfObjectIdenticalTo:recvVal] != NSNotFound)
            {
            [self consumeOwnedTemp:recvVal];
            NSString* subjName = [NSString stringWithFormat:@"__forin_subj_%lu",
                                                            (unsigned long)self.currentFunction.blocks.count];
            if (!self.strongLocals)
                self.strongLocals = [NSMutableSet set];
            [self.strongLocals addObject:subjName];
            [self enrollInArcScope:subjName];
            self.locals[subjName] = recvVal;
            }
        }
    else if (collType && collType.kind == XTTypeKindPointer && [collection isKindOfClass:[XTIdentifierNode class]] && self.heapArrayLengthByLocal[((XTIdentifierNode*)collection).identName])
        {
        // Direct for-in over a heap pointer: `for (T v in buf)` where
        // `buf = new T[N]`. Use the statically-tracked count; the
        // body's baseAddr comes from lowerExpression(collection) (the
        // pointer value), not from decayArrayBaseToPtr (which would
        // give the slot's address).
        NSNumber* nN = self.heapArrayLengthByLocal[((XTIdentifierNode*)collection).identName];
        countVal = [self emitInsnOpcode:XTIROpConst
                                 result:[XTIRType u16Type]
                               operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                               value:nN.longLongValue] ]];
        isHeapPtrBase = YES;
        baseForAddr = collection;
        }
    else if (collType && collType.kind == XTTypeKindPointer && ((XTPointerType*)collType).pointeeType && ((XTPointerType*)collType).pointeeType.kind != XTTypeKindClass && [collection isKindOfClass:[XTIdentifierNode class]] && [XTPointerType heapPointerWidth] >= 4)
        {
        // For-in over a heap pointer whose count the compiler did NOT
        // record (a runtime-sized `new T[n]`). Same rule as `.length`: the
        // count comes from the allocation header via the per-runtime
        // `_xtc_count` helper, on the targets whose runtime writes one
        // (everything but the xt6502 — see the `.length` note). The class
        // case stays with the Enumerable dispatch above. private:docs/bugs/045.
        XTIRValue* hv = [self lowerExpression:collection];
        if (!hv)
            return;
        XTIRSymbolId sid = [self runtimeHelperSymbolNamed:@"_xtc_count"];
        countVal = [self emitCall:sid
                         callConv:[XTIRCallConv standard]
                        argValues:@[ hv ]
                       resultType:[self countIRType]];
        isHeapPtrBase = YES;
        baseForAddr = collection;
        }
    else
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: for-in requires an array, slice, or class instance"];
        return;
        }

    if (!countVal)
        return;

    // Build the loop and phi snapshots.
    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* headerBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_forin_header"]];
    XTIRBlock* bodyBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_forin_body"]];
    XTIRBlock* exitBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_forin_exit"]];

    XTIRBlock* preheader = self.currentBlock;
    XTIRLocalSnapshot* preSnap = [self snapshotLocals];

    // Initialize loop counter to 0 in the preheader. Its type is idxIR, and
    // the header phi picks that up from the value — as do the compare against
    // countVal and the increment, so the whole loop stays one width.
    XTIRValue* idxZero = [self emitInsnOpcode:XTIROpConst
                                       result:idxIR
                                     operands:@[ [XTIROperand immIWithType:idxIR value:0] ]];
    NSString* idxName = [NSString stringWithFormat:@"__forin_idx_%lu",
                                                   (unsigned long)self.currentFunction.blocks.count];
    self.locals[idxName] = idxZero;

    [self emitTerminator:XTIROpBranch
                operands:@[ [XTIROperand blockWithRef:headerBlock] ]];

    // Pre-scan the body for assigned locals (excluding the loop var —
    // it is freshly loaded each iteration and does NOT need an SSA phi).
    NSMutableSet<NSString*>* assigned = [NSMutableSet set];
    if (node.body)
        [self collectAssignedLocalsIn:node.body into:assigned];
    NSString* varName = loopVar.varName;
    [assigned addObject:idxName];

    // Build header phis: each assigned local gets a phi with both
    // edges pointing to the entry value initially. The back-edge
    // will be patched after the body is lowered.
    NSMutableDictionary<NSString*, XTIRInsn*>* phiByName = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, XTIRValue*>* headerLocals = [NSMutableDictionary dictionary];
    for (NSString* name in preSnap)
        headerLocals[name] = preSnap[name];

    // SORTED, not the set's own order: an NSSet iterates in hash order, which
    // is stable within a build but is not a property of the program. The phi
    // ORDER at a loop header is visible in the IR text, so leaving it to the
    // hash makes the front end's output unpredictable from its input — and
    // unreproducible by any other implementation of the same lowering.
    for (NSString* name in [assigned.allObjects sortedArrayUsingSelector:@selector(compare:)])
        {
        // A name with NO pre-loop binding is not a local at all — it is a
        // GLOBAL the body assigns. It has no SSA value to merge, so it gets
        // no phi: giving it one (the index's zero was the old fallback) put
        // it in `locals`, where every later read found the phi instead of the
        // global and the write-back to memory never happened. The counted
        // loop's own index is bound in `locals` just above, so it still has
        // an entry value and still gets its phi.
        XTIRValue* entryVal = preSnap[name];
        if (!entryVal)
            {
            if (![name isEqualToString:idxName])
                continue;
            entryVal = idxZero;
            }
        XTIRType* ty = entryVal.type;
        XTIRValueId vid = [self.currentFunction allocateValueId];
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:headerBlock insnIndex:0];
        XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:ty defSite:site];
        [self.currentFunction registerValue:phiResult];
        // Set both edges to the entry value initially (back-edge patched later).
        NSArray<XTIROperand*>* operands = @[
            [XTIROperand blockWithRef:preheader],
            [XTIROperand useWithValueId:entryVal.valueId],
            [XTIROperand blockWithRef:bodyBlock],
            [XTIROperand useWithValueId:entryVal.valueId],
        ];
        XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                  result:phiResult
                                                operands:operands
                                                  dbgLoc:nil];
        [headerBlock.phiNodes addObject:phi];
        phiByName[name] = phi;
        headerLocals[name] = phiResult;
        }

    // Header: check idx < count (unsigned less-than).
    self.currentBlock = headerBlock;
    self.locals = headerLocals;
    XTIRValue* idxH = headerLocals[idxName];
    XTIRValue* cmp = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
    XTIRInsn* icmp = [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                               result:cmp
                                             operands:@[ [XTIROperand useWithValueId:idxH.valueId],
                                                         [XTIROperand useWithValueId:countVal.valueId] ]
                                            predicate:XTIRICmpULT
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:icmp];
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cmp.valueId],
                            [XTIROperand blockWithRef:bodyBlock],
                            [XTIROperand blockWithRef:exitBlock] ]];

    // Body: load element, assign to loopVar, execute body.
    NSMutableArray* breaks = [NSMutableArray array];
    NSMutableArray* continues = [NSMutableArray array];
    [self.loopStack addObject:@{@"header" : headerBlock,
                                @"arcDepth" : @(self.arcScopeStack.count),
                                @"exit" : exitBlock,
                                @"breaks" : breaks,
                                @"continues" : continues,
                                // for-in advances its index at the body's end
                                // (below), which a `continue` skips — so the
                                // continue handler must advance it too, just
                                // as a C-style `for` replays its increment.
                                @"forinIdxName" : idxName,
                                // …and it must advance it at the SAME width
                                // the loop counts in, or the continue edge
                                // feeds a differently-typed value to the phi.
                                @"forinIdxType" : idxIR}];

    self.currentBlock = bodyBlock;
    self.locals = [headerLocals mutableCopy];
    XTIRValue* idxB = self.locals[idxName];

    // Compute element address: basePtr[idxB] (deferred AddrOf so the
    // array's SSA value stays live across calls in the loop body).
    XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
    XTIRValue* baseAddr = nil;
    XTIRValue* indexVal = idxB;

    if (isArrayBase)
        {
        baseAddr = [self decayArrayBaseToPtr:baseForAddr elemPtr:elemPtrIR location:node.location];
        if (!baseAddr)
            return;
        }
    else if (isHeapPtrBase)
        {
        // Heap pointer collection: the base address is the pointer
        // VALUE (loaded from the local's slot), not the slot's address.
        baseAddr = [self lowerExpression:baseForAddr];
        if (!baseAddr)
            return;
        }
    else if (isSliceBase)
        {
        if (baseForAddr)
            {
            // Array base: decay to pointer to element 0.
            baseAddr = [self decayArrayBaseToPtr:baseForAddr elemPtr:elemPtrIR location:node.location];
            }
        else
            {
            // Pointer base: lower the expression.
            XTSliceExprNode* slice = (XTSliceExprNode*)collection;
            baseAddr = [self lowerExpression:slice.base];
            }
        if (!baseAddr)
            return;
        // Adjust the element index by the slice start offset. Count-typed like
        // the counter and the start bound — all three are element indices.
        indexVal = [self emitInsnOpcode:XTIROpAdd
                                 result:[self countIRType]
                               operands:@[ [XTIROperand useWithValueId:idxB.valueId],
                                           [XTIROperand useWithValueId:sliceByteOff.valueId] ]];
        }

    XTIRValue* elemVal = nil;
    if (isClassEnum)
        {
        // Class-instance collection: call enumAt(index) via vtable dispatch.
        elemVal = [self emitVTblDispatch:classEnumRecv
                                    slot:classEnumAtSlot
                               argValues:@[ indexVal ]
                              resultType:elemIR];
        // enumAt is an ordinary method, so under the uniform +1 return
        // convention it hands back a RETAINED element. The loop variable is
        // borrowed (see the note below), so that +1 is balanced here and now:
        // the container holds the element for the whole loop, which is exactly
        // the assumption the borrowed binding already rests on. Without this,
        // every `for (x in collection)` leaked one reference per element.
        if ([self irValueIsPointer:elemVal] && [self astTypeIsClassPointer:elemAST])
            [self emitRelease:elemVal];
        }
    else
        {
        XTIRValue* elemAddr = [self emitInsnOpcode:XTIROpElementAddr
                                            result:elemPtrIR
                                          operands:@[ [XTIROperand useWithValueId:baseAddr.valueId],
                                                      [XTIROperand useWithValueId:indexVal.valueId] ]];
        // Load the element value.
        elemVal = [self emitLoad:elemAddr pointeeType:elemIR];
        }

    // Register the loop variable in locals (SSA binding).
    self.locals[varName] = elemVal;

    // The loop variable is BORROWED, not owned: the element belongs to the
    // container being walked, and the loop is only looking at it. So it is
    // deliberately NOT registered as a strong local — no retain on the way in,
    // and no release on the way out.
    //
    // It used to be registered. That did nothing on the normal exit path (by
    // the time the enclosing scope was popped, the loop variable's binding was
    // gone, so the release was skipped), but a `return` from INSIDE the loop
    // body walks the ARC scopes with the binding still live — and released an
    // element the container still owned.
    //
    //     for (Object@ o in items) { if (match(o)) return true; }
    //
    // That is the plainest shape there is — a linear search — and it dropped a
    // refcount on the container's element every time it found what it was
    // looking for. Set.intersects and Set.isSubsetOf are written exactly that
    // way, which is how it surfaced: a Set freed out from under itself after a
    // few queries, then faulted in _findSlot with a null table.

    // Lower the body.
    if (node.body)
        [self lowerStatement:node.body];
    if (self.aborted)
        {
        [self.loopStack removeLastObject];
        return;
        }

    // Increment counter.
    XTIRValue* one = [self emitInsnOpcode:XTIROpConst
                                   result:idxIR
                                 operands:@[ [XTIROperand immIWithType:idxIR value:1] ]];
    XTIRValue* nextIdx = [self emitInsnOpcode:XTIROpAdd
                                       result:idxIR
                                     operands:@[ [XTIROperand useWithValueId:self.locals[idxName].valueId],
                                                 [XTIROperand useWithValueId:one.valueId] ]];
    self.locals[idxName] = nextIdx;

    XTIRBlock* bodyExit = self.currentBlock;
    BOOL bodyFellThrough = (bodyExit.terminator == nil);
    if (bodyFellThrough)
        {
        [self emitTerminator:XTIROpBranch
                    operands:@[ [XTIROperand blockWithRef:headerBlock] ]];
        }
    NSDictionary* frame = self.loopStack.lastObject;
    NSArray* continueEdges = frame[@"continues"];
    [self.loopStack removeLastObject];

    // Rebuild each header phi with actual back-edge values (including
    // edges from `continue` statements, which also branch back to header).
    for (NSString* name in phiByName)
        {
        XTIRInsn* phi = phiByName[name];
        XTIRValue* entryVal = preSnap[name] ?: idxZero;
        NSMutableArray<NSArray*>* pairs = [NSMutableArray array];
        [pairs addObject:@[ preheader, entryVal ]];
        if (bodyFellThrough)
            {
            [pairs addObject:@[ bodyExit, (self.locals[name] ?: entryVal) ]];
            }
        for (NSDictionary* rec in continueEdges)
            {
            XTIRLocalSnapshot* cl = rec[@"locals"];
            [pairs addObject:@[ rec[@"block"], (cl[name] ?: entryVal) ]];
            }
        // Sort by block index (verifier §12.4).
        [pairs sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) {
          NSUInteger ia = [self.currentFunction.blocks indexOfObjectIdenticalTo:a[0]];
          NSUInteger ib = [self.currentFunction.blocks indexOfObjectIdenticalTo:b[0]];
          return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (NSArray* p in pairs)
            {
            [ops addObject:[XTIROperand blockWithRef:p[0]]];
            [ops addObject:[XTIROperand useWithValueId:((XTIRValue*)p[1]).valueId]];
            }
        [phi setValue:[ops copy] forKey:@"operands"];
        }

    // Set exit locals: header→exit edge contributes the phi values
    // (where the condition failed), plus break edges.
    self.currentBlock = exitBlock;
    [self bindLoopExitLocalsInBlock:exitBlock
                        headerBlock:headerBlock
                  headerReachesExit:YES
                       headerLocals:headerLocals
                             breaks:breaks];
    }

#pragma mark - break / continue

// Set `self.locals` for a loop's exit block, merging the values that
// flow in along each exit edge: the header→exit edge (the loop-carried
// value where the condition failed) plus one edge per `break` (the
// value at that break point). Where a local differs across edges a phi
// is inserted in exitBlock; otherwise the common value is reused.
// `breaks` empty → no break edges, so the exit has the single
// header→exit predecessor and `self.locals` is just headerLocals.
- (void)bindLoopExitLocalsInBlock:(XTIRBlock*)exitBlock
                      headerBlock:(XTIRBlock*)headerBlock
                headerReachesExit:(BOOL)headerReachesExit
                     headerLocals:(NSDictionary<NSString*, XTIRValue*>*)headerLocals
                           breaks:(NSArray<NSDictionary*>*)breaks
    {
    self.locals = [headerLocals mutableCopy];
    if (breaks.count == 0)
        return;

    // SORTED — this loop CREATES phis (one per local a `break` disagrees
    // about), so a dictionary's hash order would reach the IR text. Same
    // reason as the assigned-locals scan and the join merge.
    for (NSString* name in [headerLocals.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        XTIRValue* headerVal = headerLocals[name];
        NSMutableArray<NSArray*>* pairs = [NSMutableArray array];
        if (headerReachesExit)
            {
            [pairs addObject:@[ headerBlock, headerVal ]];
            }
        for (NSDictionary* rec in breaks)
            {
            XTIRLocalSnapshot* bl = rec[@"locals"];
            [pairs addObject:@[ rec[@"block"], (bl[name] ?: headerVal) ]];
            }
        // No differing values → reuse the common one (it dominates the
        // exit from every edge), avoiding a needless phi.
        BOOL allSame = YES;
        XTIRValue* first = pairs.firstObject[1];
        for (NSArray* p in pairs)
            {
            if (p[1] != first)
                {
                allSame = NO;
                break;
                }
            }
        if (pairs.count <= 1 || allSame)
            {
            if (first)
                self.locals[name] = first;
            continue;
            }
        [pairs sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) {
          NSUInteger ia = [self.currentFunction.blocks indexOfObjectIdenticalTo:a[0]];
          NSUInteger ib = [self.currentFunction.blocks indexOfObjectIdenticalTo:b[0]];
          return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
        }];
        XTIRValueId vid = [self.currentFunction allocateValueId];
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:exitBlock insnIndex:0];
        XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid
                                                             type:((XTIRValue*)first).type
                                                          defSite:site];
        [self.currentFunction registerValue:phiResult];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (NSArray* p in pairs)
            {
            [ops addObject:[XTIROperand blockWithRef:p[0]]];
            [ops addObject:[XTIROperand useWithValueId:((XTIRValue*)p[1]).valueId]];
            }
        XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                  result:phiResult
                                                operands:ops
                                                  dbgLoc:nil];
        [exitBlock.phiNodes addObject:phi];
        self.locals[name] = phiResult;
        }
    }

#pragma mark - Switch

// Fold a case-label expression to a constant: integer/char/bool/const-expr
// (via tryFoldInitialiserInt:) or a bare enum-constant identifier.
- (BOOL)caseLabelConst:(XTASTNode*)node value:(int64_t*)out
    {
    if ([self tryFoldInitialiserInt:node value:out])
        return YES;
    if (node.nodeKind == XTASTNodeKindIdentifier)
        {
        NSNumber* ev = self.enumConstants[((XTIdentifierNode*)node).identName];
        if (ev)
            {
            *out = ev.longLongValue;
            return YES;
            }
        }
    return NO;
    }

// Emit `subjVal <pred> Const(k)` as a Bool, k at the subject's IR width.
// Emit an inline value→name lookup for one enum-typed `%e` argument.
// Walks the enum's members and folds a chain of `Select(eq?, name, prev)`,
// starting from a `"?"` default. The IR is a flat chain (no new blocks),
// so the emit is local — the surrounding call site stays straight-line.
// Each member's name is emitted via the shared string-constant cache so
// the same name across multiple call sites and enums is deduped.
- (XTIRValue*)emitEnumNameLookup:(XTIRValue*)val
                        enumType:(XTEnumType*)et
    {
    XTIRType* u8Ptr = [XTIRType ptrToType:[XTIRType u8Type]
                                   window:XTIRWindowUnbanked];
    XTIRValue* result = [self emitStringConstant:@"?"];
    NSDictionary<NSString*, NSNumber*>* members = et.members;
    // Sort members by value (stable, first-declared-wins on ties) so
    // the chain has a deterministic shape across runs.
    NSArray<NSString*>* names = [members.allKeys sortedArrayUsingComparator:
                                                     ^NSComparisonResult(NSString* a, NSString* b) {
                                                       int64_t av = members[a].longLongValue;
                                                       int64_t bv = members[b].longLongValue;
                                                       if (av != bv)
                                                           return av < bv ? NSOrderedAscending : NSOrderedDescending;
                                                       return [a compare:b];
                                                     }];
    for (NSString* name in names)
        {
        XTIRValue* cmp = [self emitICmp:val
                                   pred:XTIRICmpEQ
                                  const:members[name].longLongValue];
        XTIRValue* nameStr = [self emitStringConstant:name];
        XTIRValue* next = [self allocateValueOfType:u8Ptr
                                             atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpSelect
                                                         result:next
                                                       operands:@[ [XTIROperand useWithValueId:cmp.valueId],
                                                                   [XTIROperand useWithValueId:nameStr.valueId],
                                                                   [XTIROperand useWithValueId:result.valueId] ]
                                                         dbgLoc:nil]];
        result = next;
        }
    return result;
    }

// `%e` printf rewrite: scans a format literal for `%e` and, for each one
// whose matching argument is enum-typed, replaces the format-string
// specifier with `%s` AND rewrites the corresponding IR arg with an
// inline `emitEnumNameLookup`. The format-string arg lives at
// `fmtArgIdx` (varargs follow). Returns YES if anything was rewritten;
// the caller's vararg packing then runs on the modified `args`.
- (BOOL)rewriteEnumPercentEInArgs:(NSMutableArray<XTIRValue*>*)args
                          astArgs:(NSArray<XTASTNode*>*)astArgs
                           fmtIdx:(NSUInteger)fmtArgIdx
    {
    if (fmtArgIdx >= astArgs.count)
        return NO;
    XTASTNode* fmtNode = astArgs[fmtArgIdx];
    if (![fmtNode isKindOfClass:[XTLiteralStringNode class]])
        return NO;
    NSString* fmt = ((XTLiteralStringNode*)fmtNode).stringValue;

    NSMutableString* newFmt = [NSMutableString string];
    NSMutableArray<NSNumber*>* eArgIndices = [NSMutableArray array];
    BOOL anyRewrite = NO;
    NSUInteger n = fmt.length, i = 0;
    NSUInteger specCount = 0; // running varargs spec count
    while (i < n)
        {
        unichar c = [fmt characterAtIndex:i++];
        if (c != '%' || i >= n)
            {
            [newFmt appendFormat:@"%C", c];
            continue;
            }
        // Optional `.precision`: copy through, doesn't introduce a new
        // arg (precision is part of the same spec).
        NSMutableString* precRun = [NSMutableString string];
        if ([fmt characterAtIndex:i] == '.')
            {
            [precRun appendString:@"."];
            i++;
            while (i < n)
                {
                unichar pc = [fmt characterAtIndex:i];
                if (pc < '0' || pc > '9')
                    break;
                [precRun appendFormat:@"%C", pc];
                i++;
                }
            }
        if (i >= n)
            {
            [newFmt appendFormat:@"%%%@", precRun];
            break;
            }
        unichar next = [fmt characterAtIndex:i];
        if (next == '%')
            {
            [newFmt appendFormat:@"%%%@%%", precRun];
            i++;
            continue;
            }
        if (next == 'l')
            {
            // `%l<x>` consumes one extra spec char and one arg.
            i++;
            if (i < n)
                {
                unichar sub = [fmt characterAtIndex:i++];
                [newFmt appendFormat:@"%%%@l%C", precRun, sub];
                }
            else
                {
                [newFmt appendFormat:@"%%%@l", precRun];
                }
            specCount++;
            continue;
            }
        if (next == 'e')
            {
            NSUInteger argIdx = fmtArgIdx + 1 + specCount;
            XTType* argT = (argIdx < astArgs.count) ? astArgs[argIdx].resolvedType : nil;
            if ([argT isKindOfClass:[XTEnumType class]])
                {
                [newFmt appendFormat:@"%%%@s", precRun];
                [eArgIndices addObject:@(argIdx)];
                anyRewrite = YES;
                i++;
                specCount++;
                continue;
                }
            }
        [newFmt appendFormat:@"%%%@%C", precRun, next];
        i++;
        specCount++;
        }
    if (!anyRewrite)
        return NO;

    for (NSNumber* idxN in eArgIndices)
        {
        NSUInteger argIdx = idxN.unsignedIntegerValue;
        XTEnumType* et = (XTEnumType*)astArgs[argIdx].resolvedType;
        XTIRValue* lookup = [self emitEnumNameLookup:args[argIdx] enumType:et];
        if (lookup)
            args[argIdx] = lookup;
        }
    XTIRValue* newFmtPtr = [self emitStringConstant:newFmt];
    if (newFmtPtr)
        args[fmtArgIdx] = newFmtPtr;
    return YES;
    }

- (XTIRValue*)emitICmp:(XTIRValue*)subjVal pred:(uint8_t)pred const:(int64_t)k
    {
    XTIRType* ty = subjVal.type;
    XTIRValue* c = [self allocateValueOfType:ty atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                   result:c
                                                                 operands:@[ [XTIROperand immIWithType:ty value:k] ]
                                                                   dbgLoc:nil]];
    XTIRValue* r = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
    [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                                   result:r
                                                                 operands:@[ [XTIROperand useWithValueId:subjVal.valueId],
                                                                             [XTIROperand useWithValueId:c.valueId] ]
                                                                predicate:pred
                                                                   dbgLoc:nil]];
    return r;
    }

// Bool "does the subject match this case label" — `== v` for a single
// value, or a (possibly half-open) range test for `lo..hi` / `..hi` /
// `lo..`. nil if a bound isn't a constant.
- (nullable XTIRValue*)emitCaseLabelMatch:(XTCaseLabel*)label
                                  subject:(XTIRValue*)subjVal
                                   signed:(BOOL)sgn
    {
    if (!label.isRange)
        {
        int64_t v;
        if (![self caseLabelConst:label.singleValue value:&v])
            return nil;
        return [self emitICmp:subjVal pred:XTIRICmpEQ const:v];
        }
    int64_t lo = 0, hi = 0;
    BOOL haveLo = NO, haveHi = NO;
    if (label.rangeLo)
        haveLo = [self caseLabelConst:label.rangeLo value:&lo];
    if (label.rangeHi)
        haveHi = [self caseLabelConst:label.rangeHi value:&hi];
    if (label.rangeLo && !haveLo)
        return nil;
    if (label.rangeHi && !haveHi)
        return nil;
    XTIRValue* geLo = haveLo ? [self emitICmp:subjVal pred:(sgn ? XTIRICmpSGE : XTIRICmpUGE) const:lo] : nil;
    XTIRValue* leHi = haveHi ? [self emitICmp:subjVal pred:(sgn ? XTIRICmpSLE : XTIRICmpULE) const:hi] : nil;
    if (geLo && leHi)
        return [self emitInsnOpcode:XTIROpAnd
                             result:[XTIRType boolType]
                           operands:@[ [XTIROperand useWithValueId:geLo.valueId],
                                       [XTIROperand useWithValueId:leHi.valueId] ]];
    return geLo ?: leHi;
    }

// Lower `switch (subj) { case …: … }`. Dispatch is a chain of equality/
// range tests branching to per-case body blocks; bodies run in source
// order with C fall-through (a body that doesn't break/return flows into
// the next); `break` exits the switch. Locals mutated across arms merge
// at the exit via the loop-frame break-edge machinery.
- (void)lowerSwitchStmt:(XTSwitchNode*)node
    {
    XTIRValue* subjVal = [self lowerExpression:node.subject];
    if (!subjVal)
        return;
    BOOL sgn = node.subject.resolvedType.isSigned;
    NSDictionary<NSString*, XTIRValue*>* entryLocals = [self.locals copy];

    NSUInteger n = node.cases.count;
    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    NSMutableArray<XTIRBlock*>* bodyBlocks = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++)
        [bodyBlocks addObject:[self addBlockWithName:
                                        [NSString stringWithFormat:@"%@_sw%lu", prefix, (unsigned long)i]]];
    XTIRBlock* exitBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_sw_exit"]];

    // The block that branches INTO each case body along the dispatch edge (the
    // test that matched it; the no-match branch for a default). A case body that
    // a preceding case falls through to has this plus a fall-through edge, and
    // the two must be merged with phis — see the bodies loop below.
    NSMutableArray* dispatchPreds = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
        [dispatchPreds addObject:[NSNull null]];

    NSInteger defaultIdx = -1;
    for (NSUInteger i = 0; i < n; i++)
        if (node.cases[i].isDefault)
            {
            defaultIdx = (NSInteger)i;
            break;
            }

    NSMutableArray* breaks = [NSMutableArray array];
    [self.loopStack addObject:@{@"exit" : exitBlock, @"breaks" : breaks, @"isSwitch" : @YES, @"arcDepth" : @(self.arcScopeStack.count)}];

    // Dispatch chain — one CondBranch per non-default arm.
    for (NSUInteger i = 0; i < n; i++)
        {
        XTSwitchCase* arm = node.cases[i];
        if (arm.isDefault)
            continue;
        XTIRValue* match = nil;
        for (XTCaseLabel* label in arm.labels)
            {
            XTIRValue* m = [self emitCaseLabelMatch:label subject:subjVal signed:sgn];
            if (!m)
                {
                [self.loopStack removeLastObject];
                [self softFailLoweringAt:node.location
                             withMessage:@"lowering: switch case label is not a constant"];
                return;
                }
            match = match ? [self emitInsnOpcode:XTIROpOr
                                          result:[XTIRType boolType]
                                        operands:@[ [XTIROperand useWithValueId:match.valueId],
                                                    [XTIROperand useWithValueId:m.valueId] ]]
                          : m;
            }
        XTIRBlock* nextTest = [self addBlockWithName:
                                        [NSString stringWithFormat:@"%@_swt%lu", prefix, (unsigned long)i]];
        dispatchPreds[i] = self.currentBlock;
        [self emitTerminator:XTIROpCondBranch
                    operands:@[ [XTIROperand useWithValueId:match.valueId],
                                [XTIROperand blockWithRef:bodyBlocks[i]],
                                [XTIROperand blockWithRef:nextTest] ]];
        self.currentBlock = nextTest;
        }
    // No match → default body, else fall out of the switch.
    XTIRBlock* noMatch = (defaultIdx >= 0) ? bodyBlocks[defaultIdx] : exitBlock;
    if (noMatch == exitBlock)
        [breaks addObject:@{@"block" : self.currentBlock, @"locals" : [self snapshotLocals]}];
    else
        dispatchPreds[defaultIdx] = self.currentBlock;
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:noMatch] ]];

    // Bodies in source order, each falling through to the next. A case body can
    // be entered two ways — its own dispatch edge (pre-switch locals) and a
    // fall-through from the previous case (that case's exit locals) — so when the
    // previous case fell through, merge the two with phis at the body head. Reset
    // to entryLocals otherwise (dispatch is then the only edge). Without this a
    // local a fell-through case modified reverted to its pre-switch value in the
    // next case (c2xc 01: `case 0 { for … s += i } case 1: use s` printed 0).
    XTIRBlock* prevExitBlock = nil;
    XTIRLocalSnapshot* prevExitSnap = nil;
    BOOL prevFellThrough = NO;
    for (NSUInteger i = 0; i < n; i++)
        {
        self.currentBlock = bodyBlocks[i];
        if (i > 0 && prevFellThrough)
            {
            [self bindLoopExitLocalsInBlock:bodyBlocks[i]
                                headerBlock:dispatchPreds[i]
                          headerReachesExit:YES
                               headerLocals:entryLocals
                                     breaks:@[ @{@"block" : prevExitBlock,
                                                 @"locals" : prevExitSnap} ]];
            }
        else
            {
            self.locals = [entryLocals mutableCopy];
            }
        for (XTASTNode* s in node.cases[i].body)
            {
            [self lowerStatement:s];
            if (self.aborted)
                {
                [self.loopStack removeLastObject];
                return;
                }
            }
        if (!self.currentBlock.terminator)
            {
            if (i + 1 < n)
                {
                prevExitBlock = self.currentBlock;
                prevExitSnap = [self snapshotLocals];
                prevFellThrough = YES;
                [self emitTerminator:XTIROpBranch
                            operands:@[ [XTIROperand blockWithRef:bodyBlocks[i + 1]] ]];
                }
            else
                {
                [breaks addObject:@{@"block" : self.currentBlock, @"locals" : [self snapshotLocals]}];
                [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:exitBlock] ]];
                prevFellThrough = NO;
                }
            }
        else
            {
            prevFellThrough = NO;
            }
        }

    [self.loopStack removeLastObject];

    // Merge locals at the exit from every break / fall-out / no-match edge.
    self.currentBlock = exitBlock;
    [self bindLoopExitLocalsInBlock:exitBlock
                        headerBlock:exitBlock
                  headerReachesExit:NO
                       headerLocals:entryLocals
                             breaks:breaks];
    }

// `defer { ... }` emits NOTHING at its own position — it registers the body
// against the innermost scope, and the scope-exit paths lower it inline. That is
// what makes the feature possible without closures, and it is also why a defer
// under a runtime condition is restricted (sema): registration is structural, so
// a defer that was never reached must not run, and only unconditional statement
// position guarantees that today.
// `throw e` — store the error through the hidden `$err` out-parameter, run every
// enclosing scope's defers and ARC teardown, and return. Propagation IS a return,
// which is why this reuses releaseStrongLocalsAlongReturnExcept: verbatim.
// The in-flight error channel — a single module-level slot holding the Error@
// currently propagating, or null.
//
// The design (private:docs/Design/exceptions-and-defer.md §3) called for a hidden
// trailing out-parameter, on the grounds that a global is hidden state the
// threading work would have to unpick. That is still true, but the out-param is
// not implementable on this IR: there is no alloca, locals are SSA values, and
// taking a local's address goes through a pre-scan-driven pinned-local pass — so
// a caller has nowhere to put the slot whose address it would pass. The channel
// has to be addressable storage, and a data global is the addressable storage
// the IR has.
//
// It costs nothing on the success path (one load + branch per throwing call,
// which the out-param design also paid) and needs no ABI change at all, so a
// `throws` function keeps its exact signature. XTIRSymbol already carries a
// `taskLocal` flag for when threads land; note it is a field with no backend
// implementation yet, so this slot is single-threaded state today.
- (XTIRValue*)errChannelAddress
    {
    NSString* kName = @"__xtc_inflight_err";
    XTIRSymbol* sym = nil;
    for (XTIRSymbol* s in self.module.symbols)
        {
        if ([s.name isEqualToString:kName])
            {
            sym = s;
            break;
            }
        }
    XTIRType* slotTy = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    if (!sym)
        {
        sym = [XTIRSymbol dataGlobalWithName:kName
                                        type:slotTy
                                    volatile:NO
                                     escapes:YES
                                   taskLocal:NO];
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        [self.module addSymbol:sym];
        }
    XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];
    return [self emitInsnOpcode:XTIROpAddrOf
                         result:slotTy
                       operands:@[ [XTIROperand symWithSymbolId:sid] ]];
    }

// After a call to a `throws` function: load the error channel and branch. If a
// `try` encloses the call, a raised error jumps to its handler; otherwise it
// propagates, which means running this function's own teardown and returning
// with the channel still set — the caller's check then sees it.
- (void)emitErrorCheckAfterCallAt:(XTSourceLocation*)loc
    {
    XTIRValue* slot = [self errChannelAddress];
    if (!slot || self.aborted)
        return;
    XTIRType* slotTy = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    XTIRValue* cur = [self emitLoad:slot pointeeType:slotTy];
    if (!cur)
        return;

    NSString* epfx = [NSString stringWithFormat:@"bb_%lu",
                                                (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* raised = [self addBlockWithName:[epfx stringByAppendingString:@"_err_raised"]];
    XTIRBlock* cont = [self addBlockWithName:[epfx stringByAppendingString:@"_err_ok"]];
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cur.valueId],
                            [XTIROperand blockWithRef:raised],
                            [XTIROperand blockWithRef:cont] ]];

    // Raised: either the enclosing try's handler, or propagate out of here.
    self.currentBlock = raised;
    XTIRBlock* handler = self.tryHandlerStack.lastObject;
    if (handler)
        {
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:handler] ]];
        }
    else if (self.currentFnThrows)
        {
        // Propagate: teardown, then return with the channel still set.
        [self releaseStrongLocalsAlongReturnExcept:nil];
        if (self.aborted)
            return;
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        if ([self isIntMain:self.currentFunction])
            {
            XTIRValue* z = [self emitMainExitZero];
            [ops addObject:[XTIROperand useWithValueId:z.valueId]];
            }
        [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
        [self emitTerminator:XTIROpReturn operands:ops];
        }
    else
        {
        // Sema is meant to have rejected this; be loud rather than silently
        // swallowing an error that has nowhere to go.
        [self softFailLoweringAt:loc
                     withMessage:@"lowering: call to a 'throws' function with no "
                                 @"enclosing try and no 'throws' on the caller"];
        return;
        }
    self.currentBlock = cont;
    }

- (void)lowerThrowStmt:(XTThrowNode*)node
    {
    if (!self.currentFnThrows)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: 'throw' in a function not declared 'throws'"];
        return;
        }
    XTIRValue* err = [self lowerExpression:node.operand];
    if (!err || self.aborted)
        return;

    XTIRValue* slot = [self errChannelAddress];
    if (!slot || self.aborted)
        return;
    // Store BEFORE teardown: the error was built from locals the teardown is
    // about to release.
    [self emitStore:slot value:err];

    // Every scope's defers + releases, exactly as a `return` does — propagation
    // IS a return. The thrown error is exempt: its +1 transfers to the caller.
    [self releaseStrongLocalsAlongReturnExcept:err];
    if (self.aborted)
        return;

    // The returned value is indeterminate on the throwing path — the caller's
    // generated error check guarantees it is never read. `main` is the one
    // exception: it must still yield an exit code.
    NSMutableArray<XTIROperand*>* operands = [NSMutableArray array];
    if ([self isIntMain:self.currentFunction])
        {
        XTIRValue* z = [self emitMainExitZero];
        [operands addObject:[XTIROperand useWithValueId:z.valueId]];
        }
    [operands addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
    [self emitTerminator:XTIROpReturn operands:operands];
    }

// `try { ... } catch (e) { ... }`
//
// The handler is an ordinary block. Raising calls inside the guarded block
// branch to it (see emitErrorCheckAfterCallAt:); the handler reads the error
// channel into the binder and clears it, because the error has been handled and
// must not keep propagating.
- (void)lowerTryStmt:(XTTryNode*)node
    {
    NSString* pfx = [NSString stringWithFormat:@"bb_%lu",
                                               (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* handler = [[XTIRBlock alloc] init];
    handler.name = [pfx stringByAppendingString:@"_catch"];
    XTIRBlock* join = [[XTIRBlock alloc] init];
    join.name = [pfx stringByAppendingString:@"_try_join"];

    if (!self.tryHandlerStack)
        self.tryHandlerStack = [NSMutableArray array];
    // The handler is reachable from ANY raising call in the body, so the memory
    // token live there is the one from before the body — not whatever the body
    // happened to end on. Threading the body's final token in makes the handler
    // read a value that does not dominate it.
    XTIRValue* memAtTry = self.memToken;
    // private:docs/bugs/052: every edge into the join has to bring its bindings with
    // it. `base` is what was live before the guarded block — the default for
    // any edge that did not touch a name — and each exit contributes a
    // snapshot. Without this the join merged nothing and both
    // `v = f()` (success) and `v = d` (catch) were dropped on the floor.
    XTIRLocalSnapshot* baseSnap = [self snapshotLocals];
    NSMutableArray<XTIRLocalSnapshot*>* edgeSnaps = [NSMutableArray array];
    NSMutableArray<XTIRBlock*>* edgeBlocks = [NSMutableArray array];

    [self.tryHandlerStack addObject:handler];
    [self lowerStatement:node.tryBlock];
    [self.tryHandlerStack removeLastObject];
    if (self.aborted)
        return;
    if (!self.currentBlock.terminator)
        {
        [edgeSnaps addObject:[self snapshotLocals]];
        [edgeBlocks addObject:self.currentBlock];
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:join] ]];
        }
    // The handler runs from the state BEFORE the guarded block: it is reachable
    // from any raising call inside it, so nothing the body bound can be assumed.
    [self restoreLocals:baseSnap];

    // Handler: load the in-flight error, then test the arms in SOURCE ORDER.
    [self.currentFunction.blocks addObject:handler];
    self.currentBlock = handler;
    self.memToken = memAtTry;

    XTIRType* slotTy = [XTIRType ptrToType:[XTIRType voidType] window:XTIRWindowUnbanked];
    XTIRValue* slot = [self errChannelAddress];
    if (!slot || self.aborted)
        return;
    XTIRValue* errVal = [self emitLoad:slot pointeeType:slotTy];
    if (!errVal || self.aborted)
        return;

    // The error is being handled here, so clear the channel. If no arm matches
    // it is re-raised below, which stores it back.
    XTIRValue* nullv = [self emitInsnOpcode:XTIROpConst
                                     result:slotTy
                                   operands:@[ [XTIROperand immIWithType:slotTy value:0] ]];
    if (nullv)
        [self emitStore:slot value:nullv];

    for (XTCatchClause* c in node.catchClauses)
        {
        if (self.aborted)
            return;
        XTIRClassInfo* ci = c.typeName.length ? self.classesByName[c.typeName] : nil;

        XTIRBlock* armBlk = nil;
        XTIRBlock* nextBlk = nil;
        if (ci)
            {
            // Typed arm: run it only when the error really is that class. The
            // failable downcast is the same RTTI check `(T@ ?)obj` uses, so it
            // works across module boundaries for free.
            XTIRValue* cast = [self lowerClassDowncastFrom:errVal
                                               sourceClass:nil
                                               targetClass:ci
                                                resultType:ci.selfPtrType
                                                  failable:YES];
            if (!cast || self.aborted)
                return;
            NSString* apfx = [NSString stringWithFormat:@"bb_%lu",
                                                        (unsigned long)self.currentFunction.blocks.count];
            armBlk = [self addBlockWithName:[apfx stringByAppendingString:@"_arm"]];
            nextBlk = [self addBlockWithName:[apfx stringByAppendingString:@"_arm_next"]];
            [self emitTerminator:XTIROpCondBranch
                        operands:@[ [XTIROperand useWithValueId:cast.valueId],
                                    [XTIROperand blockWithRef:armBlk],
                                    [XTIROperand blockWithRef:nextBlk] ]];
            self.currentBlock = armBlk;
            if (c.varName.length)
                self.locals[c.varName] = cast;
            }
        else
            {
            // Untyped arm catches everything; no test, and nothing after it can
            // run (sema warns about arms it shadows).
            if (c.varName.length)
                self.locals[c.varName] = errVal;
            }

        [self pushArcScope];
        [self lowerStatement:c.block];
        if (self.aborted)
            return;
        if (self.currentBlock.terminator)
            [self popArcScopeEmittingReleases:NO];
        else
            [self popArcScopeEmittingReleases:YES];
        if (!self.currentBlock.terminator)
            {
            [edgeSnaps addObject:[self snapshotLocals]];
            [edgeBlocks addObject:self.currentBlock];
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:join] ]];
            }

        if (!nextBlk)
            break; // untyped arm ends the chain
        self.currentBlock = nextBlk;
        // The next arm is tested from the pre-try state too — an arm that ran
        // is not on the path to the arm after it.
        [self restoreLocals:baseSnap];
        }

    // Fell past every arm: the error matched none of them, so it keeps
    // propagating rather than being silently swallowed. Put it back on the
    // channel and take the same path a raising call with no handler takes.
    if (!self.currentBlock.terminator)
        {
        if (slot && errVal)
            [self emitStore:slot value:errVal];
        XTIRBlock* outer = self.tryHandlerStack.lastObject;
        if (outer)
            {
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:outer] ]];
            }
        else if (self.currentFnThrows)
            {
            [self releaseStrongLocalsAlongReturnExcept:errVal];
            if (self.aborted)
                return;
            NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
            if ([self isIntMain:self.currentFunction])
                {
                XTIRValue* z = [self emitMainExitZero];
                [ops addObject:[XTIROperand useWithValueId:z.valueId]];
                }
            [ops addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
            [self emitTerminator:XTIROpReturn operands:ops];
            }
        else
            {
            // Nowhere to send it. Rather than swallow, fall through to the join
            // with the channel set — the next checked call, or the program end,
            // sees it. Sema warns when a try has only typed arms in a
            // non-throwing function.
            [edgeSnaps addObject:[self snapshotLocals]];
            [edgeBlocks addObject:self.currentBlock];
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:join] ]];
            }
        }

    [self.currentFunction.blocks addObject:join];
    self.currentBlock = join;
    [self mergeAtJoin:join snapshots:edgeSnaps throughBlocks:edgeBlocks base:baseSnap];
    }

- (void)lowerDeferStmt:(XTDeferNode*)node
    {
    if (!self.deferScopeStack || self.deferScopeStack.count == 0)
        {
        // No enclosing scope frame (a decl-list block shares its parent's). A
        // defer at function top level still needs somewhere to live.
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: defer outside any scope"];
        return;
        }
    [self.deferScopeStack.lastObject addObject:node];
    }

// ── goto / label (a C-porting aid; not a promoted language feature) ──────
//
// A function that contains a `goto` has ALL its locals pinned to memory (see
// the pin pre-scan), so a jump never has to reconstruct SSA values across an
// irreducible edge — every read/write goes through the slot. `goto`/`label`
// then lower to plain branches. The one thing a jump still has to do that a
// fall-through would is run the ARC releases and `defer` bodies for the scopes
// it EXITS — identical to what `break`/`return` emit — which is
// releaseScopesDownToDepth: against the target label's scope depth.

- (XTIRBlock*)blockForLabel:(NSString*)name
    {
    if (!self.labelBlocks)
        self.labelBlocks = [NSMutableDictionary dictionary];
    XTIRBlock* b = self.labelBlocks[name];
    if (!b)
        {
        b = [self addBlockWithName:[NSString stringWithFormat:@"bb_label_%@", name]];
        self.labelBlocks[name] = b;
        }
    return b;
    }

- (void)lowerLabelStmt:(XTLabelNode*)node
    {
    XTIRBlock* block = [self blockForLabel:node.labelName];
    if (self.currentBlock && !self.currentBlock.terminator)
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:block] ]];
    self.currentBlock = block;
    if (!self.labelDepths)
        self.labelDepths = [NSMutableDictionary dictionary];
    self.labelDepths[node.labelName] = @(self.arcScopeStack.count);
    }

- (void)lowerGotoStmt:(XTGotoNode*)node
    {
    NSNumber* tgtDepth = self.labelDepths[node.targetLabel];
    NSUInteger depth = tgtDepth ? tgtDepth.unsignedIntegerValue : self.arcScopeStack.count;
    if (depth > self.arcScopeStack.count)
        {
        [self softFailLoweringAt:node.location
                     withMessage:[NSString stringWithFormat:
                                               @"goto '%@' jumps into a deeper scope (past a declaration), which is not allowed",
                                               node.targetLabel]];
        return;
        }
    // Run the defers + ARC releases for the scopes this jump EXITS, then branch.
    [self releaseScopesDownToDepth:depth];
    if (self.aborted)
        return;
    XTIRBlock* block = [self blockForLabel:node.targetLabel];
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:block] ]];
    // The current block is now terminated; any code up to the next label is dead
    // and lowers into it harmlessly, exactly as code after a `return` does. The
    // next `label:` starts a fresh block and does NOT fall through from here
    // (its guard sees the terminator).
    }

// Statically compute each label's scope-nesting depth, mirroring the constructs
// that push an ARC scope, so a FORWARD goto (target not yet lowered) knows how
// many scopes it exits. Depth 1 == the function body scope.
- (void)collectLabelDepthsIn:(XTASTNode*)node atDepth:(NSUInteger)depth
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindLabel:
        if (!self.labelDepths)
            self.labelDepths = [NSMutableDictionary dictionary];
        self.labelDepths[((XTLabelNode*)node).labelName] = @(depth);
        break;
    case XTASTNodeKindBlock:
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            [self collectLabelDepthsIn:st atDepth:depth];
        break;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectLabelDepthsIn:n.thenBlock atDepth:depth + 1];
        [self collectLabelDepthsIn:n.elseBlock atDepth:depth + 1];
        break;
        }
    case XTASTNodeKindWhile:
        [self collectLabelDepthsIn:((XTWhileNode*)node).body atDepth:depth + 1];
        break;
    case XTASTNodeKindForCStyle:
        [self collectLabelDepthsIn:((XTForCStyleNode*)node).body atDepth:depth + 1];
        break;
    case XTASTNodeKindForIn:
        [self collectLabelDepthsIn:((XTForInNode*)node).body atDepth:depth + 1];
        break;
    case XTASTNodeKindSwitch:
        {
        XTSwitchNode* sw = (XTSwitchNode*)node;
        for (XTSwitchCase* c in sw.cases)
            for (XTASTNode* st in c.body)
                [self collectLabelDepthsIn:st atDepth:depth + 1];
        break;
        }
    default:
        break;
        }
    }

// YES if a subtree contains a `goto` (→ pin every local so jumps are branches).
- (BOOL)astContainsGoto:(XTASTNode*)node
    {
    if (!node)
        return NO;
    switch (node.nodeKind)
        {
    case XTASTNodeKindGoto:
        return YES;
    case XTASTNodeKindBlock:
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            if ([self astContainsGoto:st])
                return YES;
        return NO;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        return [self astContainsGoto:n.thenBlock] || [self astContainsGoto:n.elseBlock];
        }
    case XTASTNodeKindWhile:
        return [self astContainsGoto:((XTWhileNode*)node).body];
    case XTASTNodeKindForCStyle:
        return [self astContainsGoto:((XTForCStyleNode*)node).body];
    case XTASTNodeKindForIn:
        return [self astContainsGoto:((XTForInNode*)node).body];
    case XTASTNodeKindSwitch:
        {
        for (XTSwitchCase* c in ((XTSwitchNode*)node).cases)
            for (XTASTNode* st in c.body)
                if ([self astContainsGoto:st])
                    return YES;
        return NO;
        }
    default:
        return NO;
        }
    }

// A goto function is supported today only when its locals are plain scalars /
// pointers and it has no `defer` / `try` (the C-porting case). An ARC-managed
// local or a defer/try would need the jump to run releases the pinned-local
// model does not yet thread; reject rather than leak / double-free.
- (nullable NSString*)gotoUnsupportedReasonIn:(XTASTNode*)node
    {
    if (!node)
        return nil;
    switch (node.nodeKind)
        {
    case XTASTNodeKindDefer:
        return @"a `defer`";
    case XTASTNodeKindTry:
        return @"a `try`/`catch`";
    case XTASTNodeKindVariableDecl:
        {
        XTType* t = ((XTVariableDeclNode*)node).declaredType;
        if ([self astTypeIsClassPointer:t] || [self astTypeIsWeakClassPointer:t] || (t && t.boundMethodSignature != nil) || (t && t.kind == XTTypeKindStruct))
            return @"an ARC-managed local (class pointer, struct, weak, or bound method)";
        return nil;
        }
    case XTASTNodeKindBlock:
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            {
            NSString* r = [self gotoUnsupportedReasonIn:st];
            if (r)
                return r;
            }
        return nil;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        NSString* r = [self gotoUnsupportedReasonIn:n.thenBlock];
        if (r)
            return r;
        return [self gotoUnsupportedReasonIn:n.elseBlock];
        }
    case XTASTNodeKindWhile:
        return [self gotoUnsupportedReasonIn:((XTWhileNode*)node).body];
    case XTASTNodeKindForCStyle:
        return [self gotoUnsupportedReasonIn:((XTForCStyleNode*)node).body];
    case XTASTNodeKindForIn:
        return [self gotoUnsupportedReasonIn:((XTForInNode*)node).body];
    case XTASTNodeKindSwitch:
        for (XTSwitchCase* c in ((XTSwitchNode*)node).cases)
            for (XTASTNode* st in c.body)
                {
                NSString* r = [self gotoUnsupportedReasonIn:st];
                if (r)
                    return r;
                }
        return nil;
    default:
        return nil;
        }
    }

- (void)lowerBreakStmt:(XTBreakNode*)node
    {
    NSDictionary* frame = self.loopStack.lastObject;
    if (!frame)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: break outside loop"];
        return;
        }
    XTIRBlock* exit = frame[@"exit"];
    // ARC teardown for every scope this break leaves. lowerBlockStmt will see
    // the terminator below and pop those scopes WITHOUT releasing, so if we do
    // not emit here nothing ever does — which is exactly how a strong local
    // declared in a loop body used to leak on the break path.
    NSNumber* bDepth = frame[@"arcDepth"];
    if (bDepth)
        [self releaseScopesDownToDepth:bDepth.unsignedIntegerValue];
    // Record this break edge (source block + local values) so the loop
    // can build exit phis: a local mutated before the break must reach
    // post-loop code with its break-point value, not the loop-carried
    // header value.
    NSMutableArray* breaks = frame[@"breaks"];
    [breaks addObject:@{@"block" : self.currentBlock,
                        @"locals" : [self snapshotLocals]}];
    [self emitTerminator:XTIROpBranch
                operands:@[ [XTIROperand blockWithRef:exit] ]];
    }

- (void)lowerContinueStmt:(XTContinueNode*)node
    {
    // `continue` targets the nearest enclosing LOOP, skipping any switch
    // frames in between (a switch only catches `break`).
    NSDictionary* frame = nil;
    for (NSInteger i = (NSInteger)self.loopStack.count - 1; i >= 0; i--)
        {
        if (![self.loopStack[i][@"isSwitch"] boolValue])
            {
            frame = self.loopStack[i];
            break;
            }
        }
    if (!frame)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: continue outside loop"];
        return;
        }
    XTIRBlock* header = frame[@"header"];
    // ARC teardown for the scopes this continue leaves — same reasoning as
    // break. Emitted BEFORE the increment: the increment reads the loop's own
    // control variable, which lives in the enclosing scope and so is untouched
    // by this, while the body's strong locals are dead from here on.
    NSNumber* cDepth = frame[@"arcDepth"];
    if (cDepth)
        [self releaseScopesDownToDepth:cDepth.unsignedIntegerValue];
    // A C-style `for` runs its increment on `continue` before
    // retesting the condition (skipping it would leave the counter
    // unadvanced — an infinite loop). The frame carries the increment
    // expression; lower it here so each continue edge reaches the
    // header with post-increment values. While loops store no
    // increment, so this is a no-op for them.
    XTASTNode* increment = frame[@"increment"];
    if (increment && (id)increment != [NSNull null])
        {
        (void)[self lowerExpression:(XTASTNode*)increment];
        if (self.aborted)
            return;
        }
    // A for-in loop advances its synthetic index counter at the body's end;
    // `continue` jumps past that, so replay the `idx = idx + 1` here (the
    // counterpart to the C-style increment above) — otherwise the continue
    // edge feeds an unadvanced index to the header phi and the loop revisits
    // the same element.
    NSString* forinIdxName = frame[@"forinIdxName"];
    if (forinIdxName && self.locals[forinIdxName])
        {
        XTIRType* fidxIR = frame[@"forinIdxType"] ?: [self countIRType];
        XTIRValue* one = [self emitInsnOpcode:XTIROpConst
                                       result:fidxIR
                                     operands:@[ [XTIROperand immIWithType:fidxIR value:1] ]];
        XTIRValue* nextIdx = [self emitInsnOpcode:XTIROpAdd
                                           result:fidxIR
                                         operands:@[ [XTIROperand useWithValueId:self.locals[forinIdxName].valueId],
                                                     [XTIROperand useWithValueId:one.valueId] ]];
        self.locals[forinIdxName] = nextIdx;
        }
    // Record this continue edge (source block + local values) so the
    // loop can add a matching operand to each header phi — the header
    // gains a predecessor here, and §12.4 requires one phi operand per
    // predecessor.
    NSMutableArray* continues = frame[@"continues"];
    [continues addObject:@{@"block" : self.currentBlock,
                           @"locals" : [self snapshotLocals]}];
    [self emitTerminator:XTIROpBranch
                operands:@[ [XTIROperand blockWithRef:header] ]];
    }

- (void)lowerBlockStmt:(XTBlockNode*)node
    {
    // Skip the scope frame for synthetic decl-list blocks (they share
    // their enclosing scope per the AST contract). Real blocks push a
    // new ARC scope so strong-pointer locals declared inside can be
    // released on scope exit.
    BOOL pushed = NO;
    if (!node.isDeclList)
        {
        [self pushArcScope];
        pushed = YES;
        // The function body's own scope is the first one pushed, and it is
        // where an assigned parameter belongs: its lifetime is the whole
        // function, not whichever inner block happens to rebind it.
        if (self.pendingStrongParams.count && self.arcScopeStack.count == 1)
            {
            if (!self.strongLocals)
                self.strongLocals = [NSMutableSet set];
            for (NSString* pname in self.pendingStrongParams)
                {
                [self.strongLocals addObject:pname];
                [self enrollInArcScope:pname];
                }
            [self.pendingStrongParams removeAllObjects];
            }
        }
    for (XTASTNode* s in node.statements)
        {
        // Dead code after a terminator (return / break / goto) is not lowered —
        // BUT a `label:` is a goto target: it starts a fresh REACHABLE block, so
        // it and everything after it must still lower. Skip the dead run until a
        // label resets the current block; without goto in the function there are
        // no labels, so this is exactly the old "stop at the terminator" (the
        // scope is popped once, below, with releases suppressed because the
        // terminator already emitted them).
        if (self.currentBlock.terminator && s.nodeKind != XTASTNodeKindLabel)
            continue;
        [self lowerStatement:s];
        if (self.aborted)
            {
            if (pushed)
                {
                [self.arcScopeStack removeLastObject];
                if (self.shadowSaveStack.count)
                    [self.shadowSaveStack removeLastObject];
                if (self.deferScopeStack.count)
                    [self.deferScopeStack removeLastObject];
                }
            return;
            }
        }
    // The scope's releases were already emitted if the block ends terminated
    // (a return/goto/break ran them); emit them here only on a fall-out exit.
    if (pushed)
        [self popArcScopeEmittingReleases:(self.currentBlock.terminator ? NO : YES)];
    }

- (void)pushArcScope
    {
    if (!self.arcScopeStack)
        self.arcScopeStack = [NSMutableArray array];
    [self.arcScopeStack addObject:[NSMutableArray array]];
    if (!self.deferScopeStack)
        self.deferScopeStack = [NSMutableArray array];
    [self.deferScopeStack addObject:[NSMutableArray array]];
    if (!self.shadowSaveStack)
        self.shadowSaveStack = [NSMutableArray array];
    [self.shadowSaveStack addObject:[NSMutableDictionary dictionary]];
    }

// A declaration is about to BIND `name` in the current scope. If the name is
// already bound (an outer local, or a parameter), save the outer state into
// the current shadow frame so the scope's pop can restore it. First shadow
// in a frame wins — a second declaration of the same name deeper in the same
// frame shadows the FIRST shadow, whose state is by then the current one.
- (void)saveShadowedBindingsForName:(NSString*)name
    {
    if (!name.length || !self.shadowSaveStack.count)
        return;
    NSMutableDictionary<NSString*, NSDictionary*>* frame = self.shadowSaveStack.lastObject;
    if (frame[name])
        return;
    BOOL bound = (self.locals[name] != nil) || [self.strongLocals containsObject:name] || self.strongArrayLocals[name] || self.weakArrayLocals[name] || [self.weakPinnedLocals containsObject:name] || self.strongStructLocals[name] || self.strongStructArrayLocals[name] || self.pinnedLocals[name] || self.pinnedLocalASTType[name] || self.heapArrayLengthByLocal[name] || [self.arrayLocalNames containsObject:name] || self.arrayLocalElementType[name];
    if (!bound)
        return;
    NSMutableDictionary* save = [NSMutableDictionary dictionary];
    if (self.locals[name])
        save[@"local"] = self.locals[name];
    save[@"strong"] = @([self.strongLocals containsObject:name]);
    save[@"weakPinned"] = @([self.weakPinnedLocals containsObject:name]);
    save[@"arrayName"] = @([self.arrayLocalNames containsObject:name]);
    if (self.strongArrayLocals[name])
        save[@"strongArr"] = self.strongArrayLocals[name];
    if (self.weakArrayLocals[name])
        save[@"weakArr"] = self.weakArrayLocals[name];
    if (self.strongStructLocals[name])
        save[@"strongStruct"] = self.strongStructLocals[name];
    if (self.strongStructArrayLocals[name])
        save[@"strongStructArr"] = self.strongStructArrayLocals[name];
    if (self.pinnedLocals[name])
        save[@"pinned"] = self.pinnedLocals[name];
    if (self.pinnedLocalASTType[name])
        save[@"pinnedAST"] = self.pinnedLocalASTType[name];
    if (self.heapArrayLengthByLocal[name])
        save[@"heapLen"] = self.heapArrayLengthByLocal[name];
    if (self.arrayLocalElementType[name])
        save[@"arrElem"] = self.arrayLocalElementType[name];
    frame[name] = save;
    }

// Undo every binding the popped scope's declarations shadowed. Runs AFTER the
// frame's own releases (which must see the SHADOW'S bindings) and after its
// names left strongLocals. Pure table surgery — emits nothing — so iteration
// order over the frame cannot affect the IR.
- (void)restoreShadowedBindingsFromFrame:(NSDictionary<NSString*, NSDictionary*>*)frame
    {
    for (NSString* name in frame)
        {
        NSDictionary* save = frame[name];
        XTIRValue* lv = save[@"local"];
        if (lv)
            self.locals[name] = lv;
        else
            [self.locals removeObjectForKey:name];
        if ([save[@"strong"] boolValue])
            [self.strongLocals addObject:name];
        else
            [self.strongLocals removeObject:name];
        if ([save[@"weakPinned"] boolValue])
            [self.weakPinnedLocals addObject:name];
        else
            [self.weakPinnedLocals removeObject:name];
        if ([save[@"arrayName"] boolValue])
            [self.arrayLocalNames addObject:name];
        else
            [self.arrayLocalNames removeObject:name];
        if (save[@"strongArr"])
            self.strongArrayLocals[name] = save[@"strongArr"];
        else
            [self.strongArrayLocals removeObjectForKey:name];
        if (save[@"weakArr"])
            self.weakArrayLocals[name] = save[@"weakArr"];
        else
            [self.weakArrayLocals removeObjectForKey:name];
        if (save[@"strongStruct"])
            self.strongStructLocals[name] = save[@"strongStruct"];
        else
            [self.strongStructLocals removeObjectForKey:name];
        if (save[@"strongStructArr"])
            self.strongStructArrayLocals[name] = save[@"strongStructArr"];
        else
            [self.strongStructArrayLocals removeObjectForKey:name];
        if (save[@"pinned"])
            self.pinnedLocals[name] = save[@"pinned"];
        else
            [self.pinnedLocals removeObjectForKey:name];
        if (save[@"pinnedAST"])
            self.pinnedLocalASTType[name] = save[@"pinnedAST"];
        else
            [self.pinnedLocalASTType removeObjectForKey:name];
        if (save[@"heapLen"])
            self.heapArrayLengthByLocal[name] = save[@"heapLen"];
        else
            [self.heapArrayLengthByLocal removeObjectForKey:name];
        if (save[@"arrElem"])
            self.arrayLocalElementType[name] = save[@"arrElem"];
        else
            [self.arrayLocalElementType removeObjectForKey:name];
        }
    }

// Emit the `defer` bodies registered in one scope, last-registered-first.
// Called immediately BEFORE that scope's ARC teardown on every exit path.
//
// The body is lowered INLINE here rather than being called: defer is a
// statement, not a value, so there is nothing to capture and nothing to
// allocate — which is what lets the language have defer without having closures.
// A scope with several exits therefore emits the body once per exit.
- (void)emitDefersForScopeIndex:(NSUInteger)idx
    {
    if (!self.deferScopeStack || idx >= self.deferScopeStack.count)
        return;
    NSMutableArray<XTASTNode*>* bodies = self.deferScopeStack[idx];
    for (NSInteger i = (NSInteger)bodies.count - 1; i >= 0; i--)
        {
        XTDeferNode* d = (XTDeferNode*)bodies[i];
        if (!d.body)
            continue;
        // Lower the body in the scope that registered it. It must not leave a
        // terminator behind — sema rejects return/break/continue inside a defer —
        // so control falls through to the teardown that follows.
        [self lowerStatement:d.body];
        if (self.aborted)
            return;
        }
    }

// Emit the ARC teardown for ONE scope frame, innermost-last (LIFO), without
// popping it. Factored out of popArcScopeEmittingReleases so the non-local exits
// — `break` and `continue` — can run exactly the same teardown for the scopes
// they leave. They previously ran none at all (see releaseScopesDownToDepth:).
- (void)emitReleasesForScopeFrame:(NSMutableArray<NSString*>*)top
    {
    // LIFO release order — matches the user-facing ARC semantics
    // documented in the language specification's ARC section.
    for (NSInteger i = (NSInteger)top.count - 1; i >= 0; i--)
        {
        NSString* name = top[i];
            {
            if (self.strongArrayLocals[name])
                {
                [self emitStrongArrayReleaseForLocalNamed:name];
                continue;
                }
            if (self.weakArrayLocals[name])
                {
                [self emitWeakArrayUnregisterForLocalNamed:name];
                continue;
                }
            if ([self.weakPinnedLocals containsObject:name])
                {
                // Weak local (`weak:T@` / `^`): NOT owned, so no release — but
                // its side-table entry must go, or a later dealloc would write
                // through a frame slot that has since been reused.
                [self emitWeakLocalUnregisterNamed:name];
                continue;
                }
            if (self.strongStructLocals[name])
                {
                [self emitStructStrongFieldReleaseForLocalNamed:name];
                continue;
                }
            if (self.strongStructArrayLocals[name])
                {
                [self emitStructArrayARCForLocalNamed:name mode:XTStructARCRelease];
                continue;
                }
            XTIRValue* v = self.locals[name];
            if (v)
                [self emitRelease:v];
            }
        }
    }

- (void)popArcScopeEmittingReleases:(BOOL)emitReleases
    {
    if (!self.arcScopeStack || self.arcScopeStack.count == 0)
        return;
    NSMutableArray<NSString*>* top = self.arcScopeStack.lastObject;
    // Defers BEFORE releases — the body needs the locals still alive.
    if (emitReleases)
        [self emitDefersForScopeIndex:self.arcScopeStack.count - 1];
    if (emitReleases)
        [self emitReleasesForScopeFrame:top];
    for (NSString* name in top)
        [self.strongLocals removeObject:name];
    [self.arcScopeStack removeLastObject];
    if (self.deferScopeStack.count)
        [self.deferScopeStack removeLastObject];
    if (self.shadowSaveStack.count)
        {
        [self restoreShadowedBindingsFromFrame:self.shadowSaveStack.lastObject];
        [self.shadowSaveStack removeLastObject];
        }
    }

// Teardown for a NON-LOCAL exit that leaves some but not all scopes: `break` and
// `continue` unwind from the innermost scope out to (not including) `depth`, the
// arcScopeStack depth recorded when the target loop/switch frame was pushed.
//
// Scopes are NOT popped — the structural lowerBlockStmt still owns that. It sees
// the terminator these emit and pops with emitReleases:NO, so popping here would
// release twice.
//
// Without this, `break` and `continue` emitted no releases at all while still
// setting a terminator, so lowerBlockStmt dropped their scopes silently: every
// strong local declared in a loop body leaked whenever the loop was left by
// break or continue rather than by falling off the end.
- (void)releaseScopesDownToDepth:(NSUInteger)depth
    {
    if (!self.arcScopeStack)
        return;
    for (NSInteger i = (NSInteger)self.arcScopeStack.count - 1;
         i >= (NSInteger)depth && i >= 0; i--)
        {
        // Per scope: its defers, then its releases. Working innermost-out means
        // an outer defer still sees inner scopes already torn down, which is the
        // same order a normal fall-off-the-end exit produces.
        [self emitDefersForScopeIndex:(NSUInteger)i];
        if (self.aborted)
            return;
        [self emitReleasesForScopeFrame:self.arcScopeStack[(NSUInteger)i]];
        }
    }

// Release every element of a strong class-pointer ARRAY local
// (`Leaf@ arr[N]`) at scope exit. The slot is a pinned aggregate and
// each element is a class pointer the array owns, so we load and Release
// each one (the count is compile-time known, so this unrolls). Mirrors
// emitSubscriptAddress's array decay: AddrOf the slot typed as a pointer
// to the element, then ElementAddr per index strides by the element
// (class-pointer) width.
- (void)emitStrongArrayReleaseForLocalNamed:(NSString*)name
    {
    XTArrayType* at = self.strongArrayLocals[name];
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!at || !pl)
        return;
    XTIRType* elemIR = [self irTypeForASTTypeQuiet:at.elementType]; // Ptr(Agg(Leaf))
    if (!elemIR)
        return;
    XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
    for (NSInteger i = (NSInteger)at.elementCount - 1; i >= 0; i--)
        {
        XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                        result:elemPtrIR
                                      operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
        XTIRValue* idx = [self emitInsnOpcode:XTIROpConst
                                       result:[XTIRType u16Type]
                                     operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                     value:i] ]];
        XTIRValue* ea = [self emitInsnOpcode:XTIROpElementAddr
                                      result:elemPtrIR
                                    operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                [XTIROperand useWithValueId:idx.valueId] ]];
        XTIRValue* p = [self emitLoad:ea pointeeType:elemIR];
        [self emitRelease:p];
        }
    }

// Unregister every element slot of a weak class-pointer ARRAY local from the
// weak side-table at scope exit (mirrors emitStrongArrayReleaseForLocalNamed
// but WeakUnregister instead of Release — weak doesn't own, it just tracks).
// Unconditional per element: an unassigned slot has no entry, so its
// unregister is a harmless no-op. Without this, the slots' entries outlive the
// scope and a later array at the same stack addresses inherits them (weak_array
// T4). private:docs/bugs/011 #6.
/****************************************************************************\
|* Address of weak array element `i` — the SLOT base (word -2), plus the payload
|* address via `outPayload`.
|*
|* Each element of a `weak:T@ arr[N]` is a weak slot: Agg[prev, next, payload].
|* The element POINTER must be typed with the whole slot so ElementAddr's stride
|* spans the links; the payload is then field 2.
\****************************************************************************/
- (nullable XTIRValue*)weakArrayElementSlot:(NSString*)name
                                      index:(NSUInteger)i
                                 outPayload:(XTIRValue**)outPayload
    {
    XTArrayType* at = self.weakArrayLocals[name];
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!at || !pl)
        return nil;
    XTIRType* payloadIR = [self irTypeForASTTypeQuiet:at.elementType];
    if (!payloadIR)
        return nil;
    XTIRType* slotIR = [self weakSlotAggFor:payloadIR];
    XTIRType* slotPtr = [XTIRType ptrToType:slotIR window:XTIRWindowUnbanked];

    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:slotPtr
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    XTIRValue* idx = [self emitInsnOpcode:XTIROpConst
                                   result:[XTIRType u16Type]
                                 operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                 value:(int64_t)i] ]];
    if (!base || !idx)
        return nil;
    XTIRValue* ea = [self emitInsnOpcode:XTIROpElementAddr
                                  result:slotPtr
                                operands:@[ [XTIROperand useWithValueId:base.valueId],
                                            [XTIROperand useWithValueId:idx.valueId] ]];
    if (!ea)
        return nil;
    if (outPayload)
        {
        *outPayload = [self emitFieldAddr:ea
                               fieldIndex:2
                               resultType:[XTIRType ptrToType:payloadIR
                                                       window:XTIRWindowUnbanked]];
        }
    return ea;
    }

/****************************************************************************\
|* Zero every element's link words at declaration.
|*
|* A STACK array's memory is whatever the last call left there, so the elements'
|* links start as garbage and the very first unregister follows a garbage
|* `pprev` and writes through it. (An object's ivars are zero-inited by `new`;
|* a frame slot is not.)
\****************************************************************************/
- (void)emitWeakArrayLinkInitForLocalNamed:(NSString*)name
    {
    XTArrayType* at = self.weakArrayLocals[name];
    if (!at)
        return;
    XTIRType* linkTy = [XTIRType ptrToType:[XTIRType voidType]
                                    window:XTIRWindowUnbanked];
    XTIRType* linkPtr = [XTIRType ptrToType:linkTy window:XTIRWindowUnbanked];
    XTIRValue* zero = [self allocateValueOfType:linkTy atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:linkTy value:0] ]
                                                     dbgLoc:nil]];
    for (NSUInteger i = 0; i < at.elementCount; i++)
        {
        XTIRValue* slot = [self weakArrayElementSlot:name index:i outPayload:NULL];
        if (!slot)
            continue;
        for (NSUInteger f = 0; f < 2; f++)
            {
            XTIRValue* fa = [self emitFieldAddr:slot fieldIndex:f resultType:linkPtr];
            if (fa)
                [self emitStore:fa value:zero];
            }
        }
    }

- (void)emitWeakArrayUnregisterForLocalNamed:(NSString*)name
    {
    XTArrayType* at = self.weakArrayLocals[name];
    if (!at)
        return;
    for (NSInteger i = (NSInteger)at.elementCount - 1; i >= 0; i--)
        {
        XTIRValue* payload = nil;
        (void)[self weakArrayElementSlot:name index:(NSUInteger)i outPayload:&payload];
        if (payload)
            [self emitWeakUnregisterSlot:payload];
        }
    }

// YES if a struct type embeds ≥1 owned (strong/weak) class pointer, RECURSIVELY
// through nested struct fields and arrays of structs/class-pointers.
- (BOOL)structHasOwnedClassPointer:(XTStructType*)st
    {
    for (XTStructField* f in st.fields)
        if ([self astTypeOwnsClassPointer:f.fieldType])
            return YES;
    return NO;
    }
- (BOOL)astTypeOwnsClassPointer:(XTType*)ty
    {
    if ([self astTypeIsClassPointer:ty] || [self astTypeIsWeakClassPointer:ty])
        return YES;
    if ([ty isKindOfClass:[XTStructType class]])
        return [self structHasOwnedClassPointer:(XTStructType*)ty];
    if ([ty isKindOfClass:[XTArrayType class]])
        return [self astTypeOwnsClassPointer:((XTArrayType*)ty).elementType];
    return NO;
    }

// ── Recursive struct ARC walker (release / retain / zero-init) ──────────────
// Applies one ARC op to every owned class pointer reachable from a struct
// ADDRESS — direct fields, fields of nested structs, and elements of embedded
// arrays. Used for struct-local teardown, copy-retain, and zero-init so nested
// structs and arrays of structs are handled, not just flat ones.
typedef NS_ENUM(NSInteger, XTStructARCMode) {
    XTStructARCRelease = 0,  // Release strong fields, WeakUnregister weak
    XTStructARCRetain = 1,   // Retain strong fields (weak: no-op)
    XTStructARCZeroInit = 2, // Store null into strong+weak slots
};

- (void)emitClassPtrARCAt:(XTIRValue*)slot pointeeIR:(XTIRType*)pIR
                     mode:(XTStructARCMode)mode
                   strong:(BOOL)strong
    {
    switch (mode)
        {
    case XTStructARCRelease:
        if (strong)
            [self emitRelease:[self emitLoad:slot pointeeType:pIR]];
        else
            [self emitWeakUnregisterSlot:slot];
        break;
    case XTStructARCRetain:
        if (strong)
            [self emitRetain:[self emitLoad:slot pointeeType:pIR]];
        break;
    case XTStructARCZeroInit:
        {
        XTIRValue* zero = [self emitInsnOpcode:XTIROpConst
                                        result:[XTIRType u16Type]
                                      operands:@[ [XTIROperand immIWithType:[XTIRType u16Type] value:0] ]];
        XTIRValue* null = [self emitInsnOpcode:XTIROpIntToPtr
                                        result:pIR
                                      operands:@[ [XTIROperand useWithValueId:zero.valueId] ]];
        [self emitStore:slot value:null];
        break;
        }
        }
    }

- (void)emitArrayARCAt:(XTIRValue*)arrAddr arrayType:(XTArrayType*)at mode:(XTStructARCMode)mode
    {
    XTType* et = at.elementType;
    if (![self astTypeOwnsClassPointer:et])
        return;
    XTIRType* elemIR = [self irTypeForASTTypeQuiet:et];
    if (!elemIR)
        return;
    XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
    BOOL strong = [self astTypeIsClassPointer:et];
    BOOL nested = [et isKindOfClass:[XTStructType class]];
    for (NSUInteger i = 0; i < at.elementCount; i++)
        {
        XTIRValue* idxV = [self emitInsnOpcode:XTIROpConst
                                        result:[XTIRType u16Type]
                                      operands:@[ [XTIROperand immIWithType:[XTIRType u16Type] value:(int64_t)i] ]];
        XTIRValue* ea = [self emitInsnOpcode:XTIROpElementAddr
                                      result:elemPtrIR
                                    operands:@[ [XTIROperand useWithValueId:arrAddr.valueId],
                                                [XTIROperand useWithValueId:idxV.valueId] ]];
        if (nested)
            [self emitStructARCWalkAt:ea type:(XTStructType*)et mode:mode];
        else
            [self emitClassPtrARCAt:ea pointeeIR:elemIR mode:mode strong:strong];
        }
    }

- (void)emitStructARCWalkAt:(XTIRValue*)addr type:(XTStructType*)st mode:(XTStructARCMode)mode
    {
    if (!addr || !st)
        return;
    NSUInteger idx = 0;
    for (XTStructField* f in st.fields)
        {
        // An auto-zeroing field is preceded by two hidden LINK fields in the IR
        // layout — skip them, or this writes the links instead of the payload.
        if ([self astTypeIsWeakSlot:f.fieldType])
            idx += 2;
        XTType* ft = f.fieldType;
        if ([self astTypeOwnsClassPointer:ft])
            {
            XTIRType* fieldIR = [self irTypeForASTTypeQuiet:ft];
            if (fieldIR)
                {
                XTIRType* fieldPtrIR = [XTIRType ptrToType:fieldIR window:XTIRWindowUnbanked];
                XTIRValue* fa = [self emitFieldAddr:addr fieldIndex:idx resultType:fieldPtrIR];
                if ([ft isKindOfClass:[XTStructType class]])
                    [self emitStructARCWalkAt:fa type:(XTStructType*)ft mode:mode];
                else if ([ft isKindOfClass:[XTArrayType class]])
                    [self emitArrayARCAt:fa arrayType:(XTArrayType*)ft mode:mode];
                else
                    [self emitClassPtrARCAt:fa
                                  pointeeIR:fieldIR
                                       mode:mode
                                     strong:[self astTypeIsClassPointer:ft]];
                }
            }
        idx++;
        }
    }

// AddrOf a pinned struct local, typed Ptr(struct).
- (nullable XTIRValue*)addrOfPinnedStructLocalNamed:(NSString*)name
    {
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!pl)
        return nil;
    // Weak local: the payload sits past the hidden link words. See pinnedAddr:.
    return [self pinnedAddr:pl name:name outType:NULL];
    }

// Thin wrappers over the recursive walker (used by the assign/teardown sites).
- (void)emitStructStrongFieldReleaseForLocalNamed:(NSString*)name
    {
    XTStructType* st = self.strongStructLocals[name];
    XTIRValue* addr = [self addrOfPinnedStructLocalNamed:name];
    if (st && addr)
        [self emitStructARCWalkAt:addr type:st mode:XTStructARCRelease];
    }
- (void)emitStructStrongFieldRetainAt:(XTIRValue*)structAddr structType:(XTStructType*)st
    {
    [self emitStructARCWalkAt:structAddr type:st mode:XTStructARCRetain];
    }
- (void)emitStructStrongFieldZeroInitForLocalNamed:(NSString*)name
    {
    XTStructType* st = self.strongStructLocals[name];
    XTIRValue* addr = [self addrOfPinnedStructLocalNamed:name];
    if (st && addr)
        [self emitStructARCWalkAt:addr type:st mode:XTStructARCZeroInit];
    }

// Apply an ARC op to every element of a struct-array LOCAL (`Holder harr[N]`).
- (void)emitStructArrayARCForLocalNamed:(NSString*)name mode:(XTStructARCMode)mode
    {
    XTArrayType* at = self.strongStructArrayLocals[name];
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!at || !pl)
        return;
    XTIRType* elemIR = [self irTypeForASTTypeQuiet:at.elementType];
    if (!elemIR)
        return;
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:[XTIRType ptrToType:elemIR window:XTIRWindowUnbanked]
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (base)
        [self emitArrayARCAt:base arrayType:at mode:mode];
    }

// YES if `base` (a struct lvalue: identifier / nested member / subscript) roots
// at a tracked, recursively-zero-inited struct local — so a field-assign off it
// can safely release-the-old. Walks the member/subscript chain to the root id.
- (BOOL)structFieldBaseIsTrackedLocal:(XTASTNode*)base
    {
    XTASTNode* n = base;
    while (n)
        {
        if (n.nodeKind == XTASTNodeKindIdentifier)
            {
            NSString* root = ((XTIdentifierNode*)n).identName;
            return self.strongStructLocals[root] != nil || self.strongStructArrayLocals[root] != nil;
            }
        if (n.nodeKind == XTASTNodeKindMemberAccess)
            {
            n = ((XTMemberAccessNode*)n).base;
            continue;
            }
        if (n.nodeKind == XTASTNodeKindSubscriptExpr)
            {
            n = ((XTSubscriptExprNode*)n).base;
            continue;
            }
        return NO;
        }
    return NO;
    }

// Null every element of an uninitialised strong class-pointer array
// local so the scope-exit Release walker never frees a garbage slot.
- (void)emitStrongArrayZeroInitForLocalNamed:(NSString*)name
    {
    XTArrayType* at = self.strongArrayLocals[name];
    XTIRPinnedLocal* pl = self.pinnedLocals[name];
    if (!at || !pl)
        return;
    XTIRType* elemIR = [self irTypeForASTTypeQuiet:at.elementType];
    if (!elemIR)
        return;
    XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
    for (NSUInteger i = 0; i < at.elementCount; i++)
        {
        XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                        result:elemPtrIR
                                      operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
        XTIRValue* idx = [self emitInsnOpcode:XTIROpConst
                                       result:[XTIRType u16Type]
                                     operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                     value:(int64_t)i] ]];
        XTIRValue* ea = [self emitInsnOpcode:XTIROpElementAddr
                                      result:elemPtrIR
                                    operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                [XTIROperand useWithValueId:idx.valueId] ]];
        XTIRValue* zero = [self emitInsnOpcode:XTIROpConst
                                        result:[XTIRType u16Type]
                                      operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                      value:0] ]];
        XTIRValue* null = [self emitInsnOpcode:XTIROpIntToPtr
                                        result:elemIR
                                      operands:@[ [XTIROperand useWithValueId:zero.valueId] ]];
        [self emitStore:ea value:null];
        }
    }

// Emit Release for every strong-pointer local in scope, without
// disturbing the scope stack. Called by `Return` lowering before the
// terminator so the return value is still live but the locals are
// torn down per ARC. Pass the SSA value backing the return expression
// to skip its release (the +1 ownership transfers to the caller).
// Is `v` the value being returned — directly, or as the source of the Bitcast
// that is? `return (Base@)local;` hands back the cast, so a plain id comparison
// misses the local and releases it under the caller's feet.
- (BOOL)value:(XTIRValue*)v isExemptedBy:(nullable XTIRValue*)exempt
    {
    if (!v || !exempt)
        return NO;
    XTIRValue* cur = exempt;
    // bounded: casts do not chain deeply
    for (int hop = 0; cur && hop < 8; hop++)
        {
        if (cur.valueId == v.valueId)
            return YES;
        cur = self.bitcastSource[@(cur.valueId)];
        }
    return NO;
    }

- (void)releaseStrongLocalsAlongReturnExcept:(nullable XTIRValue*)retainExempt
    {
    if (self.arcScopeStack)
        {
        for (NSInteger si = (NSInteger)self.arcScopeStack.count - 1; si >= 0; si--)
            {
            // A `return` leaves every scope. Per scope: its defers, then its
            // releases — the same interleaving the other exit paths use, so a
            // defer body always sees its own scope's locals still alive.
            [self emitDefersForScopeIndex:(NSUInteger)si];
            if (self.aborted)
                return;
            NSMutableArray<NSString*>* frame = self.arcScopeStack[si];
            for (NSInteger i = (NSInteger)frame.count - 1; i >= 0; i--)
                {
                NSString* name = frame[i];
                if (self.strongArrayLocals[name])
                    {
                    [self emitStrongArrayReleaseForLocalNamed:name];
                    continue;
                    }
                if (self.weakArrayLocals[name])
                    {
                    [self emitWeakArrayUnregisterForLocalNamed:name];
                    continue;
                    }
                // A weak local (`weak:T@` or a bound method `^`) is linked into
                // its referent's weak chain so it auto-zeroes when the referent
                // dies. It is NOT owned, so there is nothing to release — but the
                // chain entry MUST come out, because the frame slot it points at
                // is about to be reused.
                //
                // popArcScopeEmittingReleases: does this. These two teardown
                // loops — the ones a `return` goes through — did not, so any
                // function that RETURNED while holding a `^` left a dead stack
                // slot on the receiver's weak list. The next time that receiver
                // was deallocated, the runtime walked the chain and wrote a zero
                // through the stale address. A comparator is exactly such a
                // function, which is how sorting an Array of Strings turned into
                // a SIGBUS inside _xtc_dealloc.
                if ([self.weakPinnedLocals containsObject:name])
                    {
                    [self emitWeakLocalUnregisterNamed:name];
                    continue;
                    }
                if (self.strongStructLocals[name])
                    {
                    // Skip the returned struct local — its +1 transfers to the
                    // caller (sret move), so its strong fields must NOT be freed.
                    if (![name isEqualToString:self.returnExemptStructName])
                        [self emitStructStrongFieldReleaseForLocalNamed:name];
                    continue;
                    }
                if (self.strongStructArrayLocals[name])
                    {
                    [self emitStructArrayARCForLocalNamed:name mode:XTStructARCRelease];
                    continue;
                    }
                XTIRValue* v = self.locals[name];
                if (!v)
                    continue;
                if ([self value:v isExemptedBy:retainExempt])
                    continue;
                [self emitRelease:v];
                }
            }
        }
    // ARC 2d: release the `self` retained on method entry — ALWAYS, even when
    // self is the return value. The +1 the caller receives from `return self`
    // is the RETURN path's own retain (self is a borrowed expression there,
    // neither an owned temp nor an enrolled strong local, so it pays the
    // return-retain like any other borrow). Exempting the prologue's count
    // here on top of that left it unbalanced — one leaked count per call,
    // and on a wrapping u16 refcount that eventually frees a live object.
    // `return (Type*)self;` never took the exemption (the compare was on raw
    // valueIds, and a Bitcast is a new value) and was already balanced, which
    // is how the imbalance stayed shape-dependent. private:docs/bugs/058.
    if (self.currentRetainedSelf)
        {
        [self emitRelease:self.currentRetainedSelf];
        }
    // Transitive ARC: a class `dealloc` releases the receiver's strong
    // class-pointer ivars after the user body. Freeing an object then
    // releases the objects it owns, and via the release dispatch their
    // ivars in turn (Outer→mid→Middle→leaf→Leaf). Emitted at every
    // return path of a dealloc method.
    [self releaseStrongIvarsForDeallocTeardown];
    }

// Release the receiver's strong class-pointer ivars — the second half
// of a class `dealloc`'s teardown. No-op unless the current function is
// a `<Class>$dealloc` with a bound `self`. Weak ivars are skipped
// (astTypeIsClassPointer excludes them). Ivars are walked in
// field-index order so the emitted IR is deterministic. Only the
// class's own ivars are released here; nested ownership unwinds through
// the release dispatch as each ivar's refcount reaches zero.
- (void)releaseStrongIvarsForDeallocTeardown
    {
    XTIRFunction* fn = self.currentFunction;
    if (!fn || ![fn.name hasSuffix:@"$dealloc"])
        return;
    XTIRClassInfo* ci = self.currentClassInfo;
    if (!ci || !self.currentSelf)
        return;
    NSArray<NSString*>* names =
        [ci.ivarFieldIndex.allKeys sortedArrayUsingComparator:
                                       ^NSComparisonResult(NSString* a, NSString* b) {
                                         return [ci.ivarFieldIndex[a] compare:ci.ivarFieldIndex[b]];
                                       }];
    for (NSString* ivarName in names)
        {
        // Release only the class's OWN strong ivars; inherited ones are
        // released by the ancestor's $dealloc via the super-chain below.
        if (ci.ownIvarNames && ![ci.ownIvarNames containsObject:ivarName])
            continue;
        XTType* ivarAST = ci.ivarASTType[ivarName];
        NSUInteger slot = ci.ivarFieldIndex[ivarName].unsignedIntegerValue;
        // Weak ivar: not owned (no Release), but its side-table entry must
        // be dropped so a later dealloc of the still-live pointee doesn't
        // write through this now-freed slot. private:docs/bugs/011 #6.
        if ([self astTypeIsWeakClassPointer:ivarAST])
            {
            XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:nil];
            if (!fieldIRType)
                continue;
            XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType
                                                  window:XTIRWindowUnbanked];
            XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                                     fieldIndex:slot
                                     resultType:fieldPtrType];
            [self emitWeakUnregisterSlot:fa];
            continue;
            }
        // A BOUND-METHOD ivar (`act_t^ f;`) is an auto-zeroing slot too — storing
        // one links it into the RECEIVER's chain (emitWeakBoundRegisterAt:), so
        // that `if (f)` goes false when the receiver dies. The link has to come
        // out again when the HOLDER dies, exactly as for a `weak:T@` ivar above:
        // otherwise the receiver's chain still points into this block, and the
        // receiver's own dealloc later walks it — writing a zero into freed
        // memory and following a `next` pointer out of it.
        //
        // That was a use-after-free reachable with no threads and no `weak`
        // keyword in sight: hold a `^` in an object, drop the object, then drop
        // the receiver. It surfaced as an allocator-recycled block being freed
        // twice, a long way from either drop.
        //
        // The registered slot is the `^`'s RECV word (aggregate field 0), and
        // this must name the SAME address the register site did — hence the
        // inner FieldAddr rather than the aggregate's own address.
        if (ivarAST.boundMethodSignature != nil)
            {
            XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:nil];
            if (!fieldIRType)
                continue;
            XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType
                                                  window:XTIRWindowUnbanked];
            XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                                     fieldIndex:slot
                                     resultType:fieldPtrType];
            if (!fa)
                continue;
            XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                          window:XTIRWindowUnbanked];
            XTIRType* ptrPtr = [XTIRType ptrToType:ptrT window:XTIRWindowUnbanked];
            XTIRValue* recvAddr = [self emitFieldAddr:fa fieldIndex:0 resultType:ptrPtr];
            if (recvAddr)
                [self emitWeakUnregisterSlot:recvAddr];
            continue;
            }
        if ([self astTypeIsClassPointer:ivarAST])
            {
            XTIRType* fieldIRType = [self irTypeForASTType:ivarAST at:nil];
            if (!fieldIRType)
                continue;
            XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType
                                                  window:XTIRWindowUnbanked];
            XTIRValue* fa = [self emitFieldAddr:self.currentSelf
                                     fieldIndex:slot
                                     resultType:fieldPtrType];
            XTIRValue* ivarVal = [self emitLoad:fa pointeeType:fieldIRType];
            [self emitRelease:ivarVal];
            continue;
            }
        // Struct-typed ivar (e.g. `Node inner;`) — recurse into the
        // embedded struct and release any strong class-pointer fields it
        // (transitively) holds. The struct's address within the instance
        // is FieldAddr(self, slot); the recursion FieldAddr's into each
        // field at its struct-relative offset.
        if (ivarAST && ivarAST.kind == XTTypeKindStruct && [ivarAST isKindOfClass:[XTStructType class]] && [self structTypeContainsStrongPointer:(XTStructType*)ivarAST])
            {
            XTIRType* structIRType = [self irTypeForASTType:ivarAST at:nil];
            if (!structIRType)
                continue;
            XTIRType* structPtrType = [XTIRType ptrToType:structIRType
                                                   window:XTIRWindowUnbanked];
            XTIRValue* structAddr = [self emitFieldAddr:self.currentSelf
                                             fieldIndex:slot
                                             resultType:structPtrType];
            [self emitArcReleaseStrongStructFieldsIndirectAt:structAddr
                                                  structType:(XTStructType*)ivarAST];
            }
        }

    // Super-chain: after this class's own teardown, run the nearest
    // ancestor's `dealloc` (child-before-parent order, witnessed by T5).
    // Skipped when the user body already calls super.dealloc() explicitly
    // (recorded in deallocCallsSuper) so it isn't doubled. The ancestor's
    // $dealloc in turn releases its own ivars and chains further up, so
    // the whole hierarchy is torn down exactly once.
    if ([self.deallocCallsSuper containsObject:ci.className])
        return;
    for (XTIRClassInfo* p = ci.parent; p != nil; p = p.parent)
        {
        NSString* pSym = [NSString stringWithFormat:@"%@$dealloc", p.className];
        XTIRSymbol* sym = [self.module symbolForName:pSym];
        if (!sym)
            continue;
        XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:sym];
        XTIRCallConv* conv = sym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                             : sym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                                   : [XTIRCallConv standard];
        (void)[self emitCall:sid
                    callConv:conv
                   argValues:@[ self.currentSelf ]
                  resultType:nil];
        return;
        }
    }

// YES if `st` (transitively) contains at least one strong class-pointer
// field — the cheap guard that keeps the dealloc walker from emitting a
// dead FieldAddr for struct ivars that own nothing.
- (BOOL)structTypeContainsStrongPointer:(XTStructType*)st
    {
    for (XTStructField* f in st.fields)
        {
        if ([self astTypeIsClassPointer:f.fieldType])
            return YES;
        if (f.fieldType.kind == XTTypeKindStruct && [f.fieldType isKindOfClass:[XTStructType class]] && [self structTypeContainsStrongPointer:(XTStructType*)f.fieldType])
            return YES;
        }
    return NO;
    }

// Release every strong class-pointer field of the struct addressed by
// `structAddr` (a Ptr to the struct's IR type), recursing into nested
// struct fields. Used by the dealloc walker so a strong pointer embedded
// inside a struct-typed ivar (`Box.inner.payload`) is released when the
// owning instance is torn down. Field index matches XTStructType.fields
// order (== XTIRLayout field order).
- (void)emitArcReleaseStrongStructFieldsIndirectAt:(XTIRValue*)structAddr
                                        structType:(XTStructType*)st
    {
    NSUInteger idx = 0;
    for (XTStructField* f in st.fields)
        {
        // An auto-zeroing field is preceded by two hidden LINK fields in the IR
        // layout — skip them, or this writes the links instead of the payload.
        if ([self astTypeIsWeakSlot:f.fieldType])
            idx += 2;
        if ([self astTypeIsClassPointer:f.fieldType])
            {
            XTIRType* fieldIRType = [self irTypeForASTType:f.fieldType at:nil];
            if (fieldIRType)
                {
                XTIRType* fieldPtrType = [XTIRType ptrToType:fieldIRType
                                                      window:XTIRWindowUnbanked];
                XTIRValue* fa = [self emitFieldAddr:structAddr
                                         fieldIndex:idx
                                         resultType:fieldPtrType];
                XTIRValue* fieldVal = [self emitLoad:fa pointeeType:fieldIRType];
                [self emitRelease:fieldVal];
                }
            }
        else if (f.fieldType.kind == XTTypeKindStruct && [f.fieldType isKindOfClass:[XTStructType class]] && [self structTypeContainsStrongPointer:(XTStructType*)f.fieldType])
            {
            XTIRType* nestedIRType = [self irTypeForASTType:f.fieldType at:nil];
            if (nestedIRType)
                {
                XTIRType* nestedPtrType = [XTIRType ptrToType:nestedIRType
                                                       window:XTIRWindowUnbanked];
                XTIRValue* nestedAddr = [self emitFieldAddr:structAddr
                                                 fieldIndex:idx
                                                 resultType:nestedPtrType];
                [self emitArcReleaseStrongStructFieldsIndirectAt:nestedAddr
                                                      structType:(XTStructType*)f.fieldType];
                }
            }
        idx++;
        }
    }

// Lower a byte-list initialiser — `{ b0, b1, … }` or `[ … ]`, both
// parsed as a block of constant items — for a SIZED SCALAR, returning
// the resulting Const value. Integers assemble the bytes little-endian
// into the value; float/double decode the xtc-format byte pattern to
// the format-neutral Const (exactly as a float literal does: the bytes
// are written in xtc's float format and each backend re-encodes).
// Missing trailing bytes zero-fill; extra bytes are dropped. Aggregate
// targets are not handled (soft-fail → nil).
- (nullable XTIRValue*)lowerScalarByteListInit:(XTBlockNode*)list
                                        toType:(nullable XTType*)astType
                                      location:(nullable XTSourceLocation*)loc
    {
    BOOL isPtr = (astType && astType.kind == XTTypeKindPointer);
    if (!astType || !(astType.isInteger || astType.isFloating || isPtr))
        {
        [self softFailLoweringAt:loc
                     withMessage:
                         @"lowering: byte-list initialiser only supported for sized scalars"];
        return nil;
        }
    XTIRType* ty = [self irTypeForASTType:astType at:loc];
    if (!ty)
        return nil;
    NSUInteger width = astType.byteWidth;
    if (width == 0 || width > 8)
        {
        [self softFailLoweringAt:loc
                     withMessage:
                         @"lowering: byte-list initialiser target has unsupported width"];
        return nil;
        }

    // Gather constant byte entries, zero-filling to the scalar width.
    // Each entry is constant-folded through the same machinery the
    // global-initialiser path uses (tryFoldInitialiserInt:), so integer
    // literals, char literals, bool literals, and constant integer
    // expressions (`'A'`, `FLAG`, `(1<<3)|2`) all become compile-time
    // bytes and keep the single-Const output. A non-foldable entry (a
    // parameter, a runtime expression) soft-fails here; callers that can
    // supply addressable storage handle that case via element-wise byte
    // stores instead (see lowerScalarByteListStoresIntoPinned:).
    uint8_t buf[8] = {0};
    NSUInteger i = 0;
    for (XTASTNode* item in list.statements)
        {
        int64_t bv = 0;
        if (![self tryFoldInitialiserInt:item value:&bv])
            {
            [self softFailLoweringAt:loc
                         withMessage:
                             @"lowering: byte-list entry is not a constant integer"];
            return nil;
            }
        if (i < width)
            {
            buf[i] = (uint8_t)(bv & 0xFF);
            }
        i++;
        }

    // Pointer target: pack the bytes into an integer of the pointer's
    // AST width and IntToPtr — the established null-pointer / pointer
    // construction (a direct Const of Ptr type is mis-sized on arm64;
    // see docs/bugs notes around phase-152).
    if (isPtr)
        {
        uint64_t v = 0;
        for (NSUInteger b = 0; b < width; b++)
            v |= (uint64_t)buf[b] << (8 * b);
        XTIRType* intTy = (width <= 1)   ? [XTIRType u8Type]
                          : (width <= 2) ? [XTIRType u16Type]
                                         : [XTIRType u32Type];
        XTIRValue* intC = [self allocateValueOfType:intTy atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:intC
                                                                     operands:@[ [XTIROperand immIWithType:intTy value:(int64_t)v] ]
                                                                       dbgLoc:nil]];
        return [self emitInsnOpcode:XTIROpIntToPtr
                             result:ty
                           operands:@[ [XTIROperand useWithValueId:intC.valueId] ]];
        }

    XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
    XTIROperand* imm;
    if (astType.isFloating)
        {
        // Bytes are xtc's float representation; decode to the abstract
        // numeric value, exactly like lowerLiteralFloat:.
        NSData* d = [NSData dataWithBytes:buf length:width];
        double value = [XTFloatEncoding doubleFromIEEEData:d];
        uint64_t raw = 0;
        memcpy(&raw, &value, sizeof(raw));
        imm = [XTIROperand immFWithType:ty rawBytes:raw];
        }
    else
        {
        uint64_t v = 0;
        for (NSUInteger b = 0; b < width; b++)
            v |= (uint64_t)buf[b] << (8 * b);
        imm = [XTIROperand immIWithType:ty value:(int64_t)v];
        }
    XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                               result:r
                                             operands:@[ imm ]
                                               dbgLoc:nil];
    [self.currentBlock appendInstruction:insn];
    return r;
    }

// Lower a byte-list initialiser (`{ … }` / `[ … ]`) for an AGGREGATE
// pinned local — an array (element-wise) or a struct (field-wise).
// Each entry is lowered as a general expression and coerced to the
// element / field type, then Stored at its computed address. Array:
// trailing elements zero-fill; extra entries are dropped. This is the
// general case the scalar-bytes path (lowerScalarByteListInit) can't
// handle. Returns NO when the target isn't an aggregate (caller falls
// through to the scalar path) or on a hard error.
// Lower a range-expression initialiser (`u8 buf[N] = 0..10;` /
// `1...5;` inclusive) for a fixed-size array local. Emit element-wise Stores
// of consecutive values into the pinned slot — same shape the byte-list
// aggregate init uses for its array branch, INCLUDING its zero-fill.
//
// The comment here used to claim sema enforced "range count matches declared
// elementCount". It does not, and nothing else did either: a range shorter
// than the array left the tail holding whatever was on the stack, while the
// equivalent `u8 a[10] = {0,1,2};` has always zero-filled. `..` EXCLUDES its
// end, so `u8 a[10] = 0..9;` — the most natural thing to write, since the last
// index is 9 — supplied nine values and left the tenth as garbage
// (private:docs/bugs/053).
- (BOOL)lowerRangeArrayInit:(XTRangeExprNode*)range
                     pinned:(XTIRPinnedLocal*)pl
                   declType:(XTType*)astType
                   location:(nullable XTSourceLocation*)loc
    {
    if (!astType || astType.kind != XTTypeKindArray || ![astType isKindOfClass:[XTArrayType class]])
        return NO;
    XTArrayType* at = (XTArrayType*)astType;
    XTType* elemAST = at.elementType;
    XTIRType* elemIR = [self irTypeForASTType:elemAST at:loc];
    if (!elemIR)
        return NO;
    int64_t s = 0, e = 0;
    if (![self tryFoldInitialiserInt:range.startExpr value:&s] || ![self tryFoldInitialiserInt:range.endExpr value:&e])
        {
        [self softFailLoweringAt:loc
                     withMessage:
                         @"lowering: range-init bounds must be constant-foldable"];
        return NO;
        }
    int64_t end = range.inclusive ? e + 1 : e;
    if (end < s)
        end = s;
    NSUInteger count = (NSUInteger)(end - s);
    XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:elemPtrIR
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base)
        return NO;
    XTIRType* u16 = [XTIRType u16Type];
    for (NSUInteger i = 0; i < count; i++)
        {
        XTIRValue* idx = [self allocateValueOfType:u16 atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:idx
                                                                     operands:@[ [XTIROperand immIWithType:u16 value:(int64_t)i] ]
                                                                       dbgLoc:nil]];
        XTIRValue* slot = [self emitInsnOpcode:XTIROpElementAddr
                                        result:elemPtrIR
                                      operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                  [XTIROperand useWithValueId:idx.valueId] ]];
        XTIRValue* v = [self allocateValueOfType:elemIR atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:v
                                                                     operands:@[ [XTIROperand immIWithType:elemIR value:s + (int64_t)i] ]
                                                                       dbgLoc:nil]];
        [self emitStore:slot value:v];
        }
    // Zero-fill the tail, exactly as a short `{ … }` list does. Deterministic
    // beats "whatever was on the stack", and it is what the language already
    // promises for the other initialiser form.
    NSUInteger declared = at.elementCount;
    for (NSUInteger i = count; i < declared; i++)
        {
        XTIRValue* idx = [self allocateValueOfType:u16 atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:idx
                                                                     operands:@[ [XTIROperand immIWithType:u16 value:(int64_t)i] ]
                                                                       dbgLoc:nil]];
        XTIRValue* slot = [self emitInsnOpcode:XTIROpElementAddr
                                        result:elemPtrIR
                                      operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                  [XTIROperand useWithValueId:idx.valueId] ]];
        XTIRValue* z = [self allocateValueOfType:elemIR atSite:self.currentBlock];
        [self.currentBlock appendInstruction:[[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                                       result:z
                                                                     operands:@[ [XTIROperand immIWithType:elemIR value:0] ]
                                                                       dbgLoc:nil]];
        [self emitStore:slot value:z];
        }
    if (declared > 0 && count != declared)
        {
        [self.diag emitWarning:[NSString stringWithFormat:
                                             @"range initialiser supplies %lu value%@ for an array of %lu — "
                                             @"the rest zero-fill%@",
                                             (unsigned long)count,
                                             count == 1 ? @"" : @"s", (unsigned long)declared,
                                             count > declared ? @" (and the extras are dropped)" : @""]
                      category:XTWarnRangeInitCount
                            at:loc];
        }
    return YES;
    }

- (BOOL)lowerAggregateByteListInit:(XTBlockNode*)list
                            pinned:(XTIRPinnedLocal*)pl
                          declType:(XTType*)astType
                          location:(nullable XTSourceLocation*)loc
    {
    // Take the pinned local's address once and dispatch to the
    // base-address variant. The base type matches astType so the IR
    // pointer reflects the aggregate's layout.
    XTIRType* baseIR = [self irTypeForASTType:astType at:loc];
    if (!baseIR)
        return NO;
    XTIRType* basePtrIR = [XTIRType ptrToType:baseIR window:XTIRWindowUnbanked];
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:basePtrIR
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base)
        return NO;
    return [self lowerAggregateByteListInitAt:base
                                     declType:astType
                                         list:list
                                     location:loc];
    }

// Base-address variant — writes a brace-list `{ … }` initialiser at the
// supplied aggregate-pointer base. Used by lowerAggregateByteListInit:
// (pinned local) and recursively by itself when a struct field / array
// element is itself a struct/array that the entry initialises with a
// nested brace-list (`Point t = {30, 40, {5, 6, 7}}`).
- (BOOL)lowerAggregateByteListInitAt:(XTIRValue*)base
                            declType:(XTType*)astType
                                list:(XTBlockNode*)list
                            location:(nullable XTSourceLocation*)loc
    {
    NSArray<XTASTNode*>* entries = list.statements;
    if (astType.kind == XTTypeKindArray && [astType isKindOfClass:[XTArrayType class]])
        {
        XTArrayType* at = (XTArrayType*)astType;
        XTType* elemAST = at.elementType;
        XTIRType* elemIR = [self irTypeForASTType:elemAST at:loc];
        if (!elemIR)
            return NO;
        NSUInteger count = at.elementCount ?: entries.count; // 0 = infer
        XTIRType* elemPtrIR = [XTIRType ptrToType:elemIR window:XTIRWindowUnbanked];
        // The base may have arrived as a Ptr(Agg) — re-cast to a
        // Ptr(elem) once so ElementAddr scales by the element type.
        XTIRValue* eBase = base;
        if (base.type.kind == XTIRTypeKindPtr && base.type != elemPtrIR)
            {
            eBase = [self emitInsnOpcode:XTIROpBitcast
                                  result:elemPtrIR
                                operands:@[ [XTIROperand useWithValueId:base.valueId] ]];
            }
        for (NSUInteger i = 0; i < count; i++)
            {
            XTIRValue* idx = [self allocateValueOfType:[XTIRType u16Type] atSite:self.currentBlock];
            XTIRInsn* ci = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:idx
                                                   operands:@[ [XTIROperand immIWithType:[XTIRType u16Type] value:(int64_t)i] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:ci];
            XTIRValue* elemAddr = [self emitInsnOpcode:XTIROpElementAddr
                                                result:elemPtrIR
                                              operands:@[ [XTIROperand useWithValueId:eBase.valueId],
                                                          [XTIROperand useWithValueId:idx.valueId] ]];
            if (i < entries.count)
                {
                XTASTNode* entry = entries[i];
                if (entry.nodeKind == XTASTNodeKindBlock && (elemAST.kind == XTTypeKindStruct || elemAST.kind == XTTypeKindArray))
                    {
                    if (![self lowerAggregateByteListInitAt:elemAddr
                                                   declType:elemAST
                                                       list:(XTBlockNode*)entry
                                                   location:loc])
                        return NO;
                    continue;
                    }
                XTIRValue* v = [self lowerExpression:entry];
                if (!v)
                    return NO;
                v = [self coerceValue:v fromType:entry.resolvedType toType:elemAST location:loc];
                [self emitStore:elemAddr value:v];
                }
            else
                {
                XTIRValue* v = [self allocateValueOfType:elemIR atSite:self.currentBlock];
                XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:v
                                                       operands:@[ [XTIROperand immIWithType:elemIR value:0] ]
                                                         dbgLoc:nil];
                [self.currentBlock appendInstruction:cz];
                [self emitStore:elemAddr value:v];
                }
            }
        return YES;
        }
    if (astType.kind == XTTypeKindStruct && [astType isKindOfClass:[XTStructType class]])
        {
        XTStructType* st = (XTStructType*)astType;
        for (NSUInteger i = 0; i < st.fields.count && i < entries.count; i++)
            {
            XTStructField* f = st.fields[i];
            XTIRType* fIR = [self irTypeForASTType:f.fieldType at:loc];
            if (!fIR)
                return NO;
            XTIRType* fPtrIR = [XTIRType ptrToType:fIR window:XTIRWindowUnbanked];
            XTIRValue* fa = [self emitFieldAddr:base fieldIndex:i resultType:fPtrIR];
            XTASTNode* entry = entries[i];
            if (entry.nodeKind == XTASTNodeKindBlock && (f.fieldType.kind == XTTypeKindStruct || f.fieldType.kind == XTTypeKindArray))
                {
                if (![self lowerAggregateByteListInitAt:fa
                                               declType:f.fieldType
                                                   list:(XTBlockNode*)entry
                                               location:loc])
                    return NO;
                continue;
                }
            XTIRValue* v = [self lowerExpression:entry];
            if (!v)
                return NO;
            v = [self coerceValue:v fromType:entry.resolvedType toType:f.fieldType location:loc];
            [self emitStore:fa value:v];
            }
        return YES;
        }
    return NO; // not an aggregate — fall through to the scalar path
    }

// YES when a sized-scalar byte-list with non-constant entries can be
// assembled by element-wise stores into a pinned slot — any integer or
// floating scalar up to 8 source bytes (u8/u16/u32, `float` = 5, and
// `double` = 8). The frame accounting is kept §12.11-consistent in the
// pre-scan (IR-type widths), and each backend sizes the real slot from
// its own byteWidthForType, so the per-byte stores stay in bounds (the
// xt6502 F32 slot is 5 bytes; arm64 uses an 8-byte value slot).
- (BOOL)scalarByteListStorableType:(nullable XTType*)astTy
    {
    if (!astTy || !(astTy.isInteger || astTy.isFloating))
        return NO;
    NSUInteger w = astTy.byteWidth;
    return w >= 1 && w <= 8;
    }

// YES when every entry of a byte-list `{ … }` folds to a compile-time
// integer (via tryFoldInitialiserInt:) — i.e. the whole list can be
// assembled into a single Const. An empty list counts as constant
// (it zero-fills). A non-foldable entry (parameter, runtime expression)
// returns NO so the caller falls back to element-wise byte stores.
- (BOOL)byteListAllConstant:(XTBlockNode*)list
    {
    for (XTASTNode* item in list.statements)
        {
        int64_t v = 0;
        if (![self tryFoldInitialiserInt:item value:&v])
            return NO;
        }
    return YES;
    }

// Lower a byte-list initialiser for a SIZED-SCALAR pinned local whose
// entries are NOT all compile-time constants (e.g. `u16 v = {lo, hi}`
// from two runtime bytes, or the Math.xc `float r = {$00, $FF, m0, m1,
// m2}` / `double r = {$00, $FF, m0…m5}` where m0… are runtime u8
// values). There is no single Const for a scalar built from runtime
// bytes, so treat the slot as a byte buffer: take its address as `u8@`,
// then for each byte offset evaluate the entry, coerce it to u8, and
// Store it. The store count is the scalar's SOURCE width (`float` = 5,
// `double` = 8); bytes beyond the list zero-fill, extra entries drop.
// Reads of the local afterwards go through the pinned AddrOf + Load,
// which re-reads the assembled bytes as the scalar's type.
//
// The byte order is the scalar's natural storage order: little-endian
// for integers (arch-neutral), and the source's literal byte pattern in
// xtc's 5-/8-byte float / double format for `float` / `double` — correct
// on xt6502 (whose float storage IS that format) but a wrong value on
// arm64 (native IEEE; the per-arch float-format gap). The store stays in
// bounds on both: the xt6502 F32 slot is 5 bytes and arm64 uses 8-byte
// value slots, so the 5 float bytes never overrun an adjacent local.
- (void)lowerScalarByteListStoresIntoPinned:(XTBlockNode*)list
                                     pinned:(XTIRPinnedLocal*)pl
                                   declType:(XTType*)astType
                                   location:(nullable XTSourceLocation*)loc
    {
    NSUInteger width = astType.byteWidth;
    if (width == 0 || width > 8)
        {
        [self softFailLoweringAt:loc
                     withMessage:
                         @"lowering: byte-list initialiser target has unsupported width"];
        return;
        }
    NSArray<XTASTNode*>* entries = list.statements;
    XTIRType* u8IR = [XTIRType u8Type];
    XTIRType* u8PtrIR = [XTIRType ptrToType:u8IR window:XTIRWindowUnbanked];
    // Byte view of the slot (`u8@` at the slot base). The pinned local's
    // frame slot is sized by the declared scalar width in the pre-scan,
    // so the per-byte stores stay within it.
    XTIRValue* base = [self emitInsnOpcode:XTIROpAddrOf
                                    result:u8PtrIR
                                  operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
    if (!base)
        return;
    for (NSUInteger i = 0; i < width; i++)
        {
        XTIRValue* idx = [self allocateValueOfType:[XTIRType u16Type] atSite:self.currentBlock];
        XTIRInsn* ci = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                 result:idx
                                               operands:@[ [XTIROperand immIWithType:[XTIRType u16Type] value:(int64_t)i] ]
                                                 dbgLoc:nil];
        [self.currentBlock appendInstruction:ci];
        XTIRValue* byteAddr = [self emitInsnOpcode:XTIROpElementAddr
                                            result:u8PtrIR
                                          operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                      [XTIROperand useWithValueId:idx.valueId] ]];
        if (!byteAddr)
            return;
        XTIRValue* bv;
        if (i < entries.count)
            {
            bv = [self lowerExpression:entries[i]];
            if (!bv)
                return;
            bv = [self coerceValue:bv
                          fromType:entries[i].resolvedType
                            toType:[XTType u8Type]
                          location:loc];
            }
        else
            {
            bv = [self allocateValueOfType:u8IR atSite:self.currentBlock];
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:bv
                                                   operands:@[ [XTIROperand immIWithType:u8IR value:0] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:cz];
            }
        [self emitStore:byteAddr value:bv];
        }
    }

- (void)lowerStaticLocalDecl:(XTVariableDeclNode*)node
    {
    // Back a function-local `static` with a persistent module global so
    // it keeps its value across calls and its initialiser runs ONCE (the
    // global's initialBytes are written at load time, not re-run on
    // entry — which is exactly C static-local semantics). Register it in
    // globalsByName under the local name so identifier reads (AddrOf+Load)
    // and assignments / `++` (AddrOf+Store) route through the existing
    // global paths. The name binding is restored when the next function
    // is lowered (see _lowerCallable).
    static NSUInteger staticLocalCounter = 0;
    XTType* astTy = node.declaredType ?: [XTType u8Type];
    XTIRType* irTy = [self irTypeForASTType:astTy at:node.location];
    if (!irTy)
        {
        [self softFailLoweringAt:node.location
                     withMessage:@"lowering: static local has no IR type"];
        return;
        }
    NSString* mangled = [NSString stringWithFormat:@"__sl_%lu_%@",
                                                   (unsigned long)(staticLocalCounter++), node.varName];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:mangled
                                                type:irTy
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    if (node.initialiser)
        {
        NSData* bytes = [self tryFoldInitialiser:node.initialiser toType:astTy];
        if (bytes)
            {
            sym.initialBytes = bytes;
            }
        else
            {
            [self.diag emitNote:[NSString stringWithFormat:
                                              @"lowering: static local '%@' initialiser not constant-foldable "
                                              @"— slot zero-initialised",
                                              node.varName]
                             at:node.location];
            }
        }
    XTIRSymbolId sid = [self.module addSymbol:sym];
    if (!self.staticLocalSaved)
        self.staticLocalSaved = [NSMutableDictionary dictionary];
    self.staticLocalSaved[node.varName] = self.globalsByName[node.varName] ?: [NSNull null];
    self.globalsByName[node.varName] = @(sid);
    }

- (void)lowerVarDecl:(XTVariableDeclNode*)node
    {
    // A declaration REBINDS its name. If an outer scope already bound it,
    // save that binding first so the scope exit can restore it (finding #16).
    if (node.varName && !(node.isStatic && !node.isGlobal))
        [self saveShadowedBindingsForName:node.varName];
    // Enrol a weak local in the scope it is DECLARED in — see
    // noteWeakPinnedLocal:. Doing it where it is ASSIGNED enrolled a local
    // declared in an outer scope into an inner one, so its side-table entry was
    // torn down at the inner scope's exit, BEFORE the object it referenced was
    // released there — and nothing ever zeroed the slot.
    if (node.varName)
        {
        [self noteWeakPinnedLocal:node.varName];
        [self emitWeakLinkInitForLocalNamed:node.varName];
        }

    // A function-local `static` is backed by a persistent module global,
    // not a per-call SSA local / frame slot — handle it before any of the
    // ordinary local-storage paths below.
    if (node.isStatic && !node.isGlobal)
        {
        [self lowerStaticLocalDecl:node];
        return;
        }
    // ARC: a local ARRAY of class pointers (`Leaf@ arr[N]`) owns each
    // element. Register it for scope-exit teardown so every element is
    // released — the slot itself is a pinned aggregate, so the scalar
    // strongLocals path (which Releases a single pointer value) can't
    // handle it. Done before the pinned-path early-returns below.
    if (node.declaredType && [node.declaredType isKindOfClass:[XTArrayType class]] && [self astTypeIsClassPointer:((XTArrayType*)node.declaredType).elementType])
        {
        if (!self.strongArrayLocals)
            self.strongArrayLocals = [NSMutableDictionary dictionary];
        self.strongArrayLocals[node.varName] = (XTArrayType*)node.declaredType;
        [self enrollInArcScope:node.varName];
        }
    // Weak local array (`weak:T@ arr[N]`): not owned, but each element slot must
    // be unregistered from the weak side-table at scope exit (else a reused
    // stack slot inherits stale entries — weak_array T4).
    if (node.declaredType && [node.declaredType isKindOfClass:[XTArrayType class]]
        // astTypeIsWeakSlot, not astTypeIsWeakClassPointer: a bound method (`^`)
        // element is an auto-zeroing slot too, and the narrower gate left a `^`
        // array with NO link-init and NO scope-exit unregister — so its links
        // held whatever the stack did. arm64 happened to see zeros and passed;
        // arm9 poisons its stack with 0xa5a5a5a5 and data-aborted.
        && [self astTypeIsWeakSlot:((XTArrayType*)node.declaredType).elementType])
        {
        if (!self.weakArrayLocals)
            self.weakArrayLocals = [NSMutableDictionary dictionary];
        self.weakArrayLocals[node.varName] = (XTArrayType*)node.declaredType;
        [self enrollInArcScope:node.varName];
        // A stack array's memory is whatever the last call left there, so each
        // element's link words must be zeroed or the first unregister follows a
        // garbage `pprev`.
        [self emitWeakArrayLinkInitForLocalNamed:node.varName];
        }
    // Struct local embedding strong/weak class pointers: register for scope-exit
    // teardown (release strong fields, unregister weak ones).
    if (node.declaredType && [node.declaredType isKindOfClass:[XTStructType class]] && [self structHasOwnedClassPointer:(XTStructType*)node.declaredType])
        {
        if (!self.strongStructLocals)
            self.strongStructLocals = [NSMutableDictionary dictionary];
        self.strongStructLocals[node.varName] = (XTStructType*)node.declaredType;
        [self enrollInArcScope:node.varName];
        }
    // A struct local with any auto-zeroing field (`weak:T@` / `^`): its hidden
    // link words are frame garbage until zeroed.
    if (node.declaredType && [node.declaredType isKindOfClass:[XTStructType class]])
        {
        [self emitStructWeakLinkInitForLocalNamed:node.varName
                                       structType:(XTStructType*)node.declaredType];
        }
    // Local ARRAY of structs that embed owned class pointers (`Holder harr[N]`):
    // register for per-element recursive zero-init + scope-exit teardown.
    if (node.declaredType && [node.declaredType isKindOfClass:[XTArrayType class]] && [((XTArrayType*)node.declaredType).elementType isKindOfClass:[XTStructType class]] && [self structHasOwnedClassPointer:(XTStructType*)((XTArrayType*)node.declaredType).elementType])
        {
        if (!self.strongStructArrayLocals)
            self.strongStructArrayLocals = [NSMutableDictionary dictionary];
        self.strongStructArrayLocals[node.varName] = (XTArrayType*)node.declaredType;
        [self enrollInArcScope:node.varName];
        }
    // Heap-array length tracking: `T@ p = new T[N];` with N foldable to
    // a compile-time integer records p → N so `p.length` becomes a Const
    // without a runtime header read. Best-effort: if the local is later
    // reassigned the entry goes stale, so a fallback in lowerMemberAccess
    // (currently a soft-fail) would need a runtime path. Covers the
    // length_prop / array_slice_heap fixtures' decl-init patterns.
    if (node.initialiser && node.initialiser.nodeKind == XTASTNodeKindNewExpr && ((XTNewExprNode*)node.initialiser).countExpr)
        {
        int64_t n = 0;
        if ([self tryFoldInitialiserInt:((XTNewExprNode*)node.initialiser).countExpr
                                  value:&n] &&
            n >= 0)
            {
            if (!self.heapArrayLengthByLocal)
                self.heapArrayLengthByLocal = [NSMutableDictionary dictionary];
            self.heapArrayLengthByLocal[node.varName] = @(n);
            }
        }
    // Pinned-local path: the slot already exists (allocated by the
    // pre-scan). Emit an AddrOf + Store of the initialiser, skip
    // the SSA-locals binding entirely. Subsequent reads go via
    // lowerIdentifier's pinned-locals branch.
    // A name re-declared at multiple types has one slot per type; rebind
    // self.pinnedLocals[name] to the slot matching THIS declaration so the
    // in-scope reads / asm-name rewrite that follow resolve to a correctly-
    // typed slot (see pinnedLocalsByType).
    NSMutableDictionary<NSString*, XTIRPinnedLocal*>* byType =
        self.pinnedLocalsByType[node.varName];
    if (byType && node.declaredType)
        {
        XTIRPinnedLocal* typed = byType[node.declaredType.displayName];
        if (typed)
            self.pinnedLocals[node.varName] = typed;
        // Rebind ARRAY-NESS to THIS declaration too. arrayLocalNames is a flat
        // per-NAME set, so an array declaration anywhere in the function made
        // every bare-name use of that name decay to the array's address — a
        // sibling block's scalar of the same name included. The scope
        // save/restore already unwinds both tables on pop, so setting them per
        // declaration is all that was missing.
        if (node.declaredType.kind == XTTypeKindArray && [node.declaredType isKindOfClass:[XTArrayType class]])
            {
            [self.arrayLocalNames addObject:node.varName];
            self.arrayLocalElementType[node.varName] =
                ((XTArrayType*)node.declaredType).elementType;
            }
        else
            {
            [self.arrayLocalNames removeObject:node.varName];
            [self.arrayLocalElementType removeObjectForKey:node.varName];
            }
        }
    XTIRPinnedLocal* pl = self.pinnedLocals[node.varName];
    if (pl)
        {
        // `<ValueClass> b = recv.clone()` where recv's class has no
        // user-defined `clone` — intercept here, at the OUTER assignment,
        // and emit a field-by-field copy from recv's slot directly into
        // b's slot. This avoids the aggregate-flow path (Load(Agg) /
        // AggBuild → Store(Agg) into a value-class slot) which doesn't
        // round-trip cleanly through both backends today, and uses the
        // same scalar FieldAddr+Load+Store pattern that already works
        // everywhere. A user-defined clone resolves as a normal method
        // call below and is unaffected.
        if (pl.type.kind == XTIRTypeKindAgg && node.initialiser && node.initialiser.nodeKind == XTASTNodeKindMethodCallExpr)
            {
            XTMethodCallExprNode* call = (XTMethodCallExprNode*)node.initialiser;
            XTIRClassInfo* vci = self.valueClassLocals[node.varName];
            if (vci && [call.methodName isEqualToString:@"clone"] && call.arguments.count == 0)
                {
                XTType* rcvT = call.receiver.resolvedType;
                XTType* rcvPointee = rcvT;
                if (rcvT && [rcvT isKindOfClass:[XTPointerType class]])
                    rcvPointee = ((XTPointerType*)rcvT).pointeeType;
                XTIRClassInfo* rcvCi = rcvPointee
                                           ? self.classesByName[rcvPointee.displayName]
                                           : nil;
                BOOL hasUserClone = NO;
                for (XTIRClassInfo* c = rcvCi; c != nil; c = c.parent)
                    {
                    NSString* cs = [NSString stringWithFormat:@"%@$clone", c.className];
                    if ([self.module symbolForName:cs])
                        {
                        hasUserClone = YES;
                        break;
                        }
                    }
                if (rcvCi && !hasUserClone)
                    {
                    XTIRValue* srcAddr = [self lowerExpression:call.receiver];
                    if (srcAddr)
                        {
                        XTIRValue* dstAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                           result:vci.selfPtrType
                                                         operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                        XTIRLayout* layout = vci.instanceLayout;
                        for (NSUInteger i = 0; i < layout.fields.count; i++)
                            {
                            XTIRType* fieldTy = layout.fields[i].type;
                            XTIRType* fieldPtrTy = [XTIRType ptrToType:fieldTy
                                                                window:XTIRWindowUnbanked];
                            XTIRValue* srcFa = [self emitFieldAddr:srcAddr
                                                        fieldIndex:i
                                                        resultType:fieldPtrTy];
                            XTIRValue* srcVal = [self emitLoad:srcFa pointeeType:fieldTy];
                            XTIRValue* dstFa = [self emitFieldAddr:dstAddr
                                                        fieldIndex:i
                                                        resultType:fieldPtrTy];
                            [self emitStore:dstFa value:srcVal];
                            }
                        return;
                        }
                    }
                }
            }
        // `<ValueClass> b = recv.method()` where the method returns a
        // class value (Big.clone, Point.translate, BumpedPoint.clone
        // overriding the byte-copy intrinsic, …). The method's IR
        // signature returns `Ptr(C)` — a pointer to the callee's just-
        // computed instance (whose lifetime survives the return long
        // enough for the caller to read it). Without this branch the
        // pinned-class path below `emitStore(addr, initVal)`s the
        // pointer VALUE into b's first 8 bytes, leaving the real ivar
        // bytes uninitialised and the test pulling garbage out of
        // b.x / b.y. Field-copy from `*initVal` into b's slot instead.
        // Mirrors the no-user-clone field-copy branch above; together
        // the two cases cover every class-value-returning init.
        if (pl.type.kind == XTIRTypeKindAgg && node.initialiser && node.initialiser.nodeKind == XTASTNodeKindMethodCallExpr)
            {
            XTIRClassInfo* vci = self.valueClassLocals[node.varName];
            if (vci)
                {
                XTIRValue* srcAddr = [self lowerExpression:node.initialiser];
                if (srcAddr && srcAddr.type.kind == XTIRTypeKindPtr)
                    {
                    XTIRValue* dstAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                       result:vci.selfPtrType
                                                     operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                    XTIRLayout* layout = vci.instanceLayout;
                    for (NSUInteger i = 0; i < layout.fields.count; i++)
                        {
                        XTIRType* fieldTy = layout.fields[i].type;
                        XTIRType* fieldPtrTy = [XTIRType ptrToType:fieldTy
                                                            window:XTIRWindowUnbanked];
                        XTIRValue* srcFa = [self emitFieldAddr:srcAddr
                                                    fieldIndex:i
                                                    resultType:fieldPtrTy];
                        XTIRValue* srcVal = [self emitLoad:srcFa pointeeType:fieldTy];
                        XTIRValue* dstFa = [self emitFieldAddr:dstAddr
                                                    fieldIndex:i
                                                    resultType:fieldPtrTy];
                        [self emitStore:dstFa value:srcVal];
                        }
                    return;
                    }
                }
            }
        // Aggregate (struct) pinned locals can't be zero-initialised
        // via a single Const + Store — there's no scalar Const op for
        // Agg. An uninit struct decl simply leaves the slot un-stored;
        // sema requires every field read to be preceded by a write.
        if (pl.type.kind == XTIRTypeKindAgg && !node.initialiser)
            {
            // Stack-allocated (value) class instance: take the slot
            // address typed as the class self-pointer and seed the
            // vtable slot so virtual / protocol dispatch and method
            // bodies work. The instance memory IS the frame slot, so
            // there's no heap alloc and nothing to free at scope exit.
            XTIRClassInfo* vci = self.valueClassLocals[node.varName];
            if (vci)
                {
                XTIRValue* addr = [self emitInsnOpcode:XTIROpAddrOf
                                                result:vci.selfPtrType
                                              operands:@[ [XTIROperand useWithValueId:pl.valueId] ]];
                if (addr)
                    {
                    // Zero the ivars first (so a strong-pointer field's
                    // first ARC store sees null), then seed the vtable.
                    [self emitZeroInitIvarsFor:addr class:vci];
                    [self emitVtableInitFor:addr class:vci];
                    // Auto-init: if the class defines a zero-arg `init()`,
                    // call it automatically after the slot is set up — same
                    // shape as a parameterised `<C> g(args)` desugaring,
                    // but for the bare `<C> g;` form.
                    XTClassDeclNode* cls = self.classDeclsByName[vci.className];
                    if (cls)
                        {
                        XTMethodDeclNode* zeroArgInit = nil;
                        for (XTMethodDeclNode* m in cls.methods)
                            {
                            if ([m.methodName isEqualToString:@"init"] && m.parameters.count == 0)
                                {
                                zeroArgInit = m;
                                break;
                                }
                            }
                        if (zeroArgInit)
                            {
                            NSString* mangled = zeroArgInit.mangledName ?: zeroArgInit.methodName;
                            NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                                           vci.className, mangled];
                            XTIRSymbol* sym = [self.module symbolForName:symName];
                            if (sym)
                                {
                                XTIRSymbolId sid =
                                    [self.module.symbols indexOfObjectIdenticalTo:sym];
                                XTIRCallConv* conv =
                                    sym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                                    : sym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                                          : [XTIRCallConv standard];
                                (void)[self emitCall:sid
                                            callConv:conv
                                           argValues:@[ addr ]
                                          resultType:nil];
                                }
                            }
                        }
                    }
                }
            // Uninitialised array of class pointers: null every element so
            // the scope-exit walker's Release of an un-assigned slot is a
            // no-op (Release of null is safe) rather than freeing garbage.
            if (self.strongArrayLocals[node.varName])
                {
                [self emitStrongArrayZeroInitForLocalNamed:node.varName];
                }
            // Uninitialised struct embedding class pointers: null its strong/weak
            // fields so the first field-assign's release-of-old and the teardown
            // read null (not stack garbage → segfault at -O2+).
            if (self.strongStructLocals[node.varName])
                {
                [self emitStructStrongFieldZeroInitForLocalNamed:node.varName];
                }
            if (self.strongStructArrayLocals[node.varName])
                {
                [self emitStructArrayARCForLocalNamed:node.varName mode:XTStructARCZeroInit];
                }
            return;
            }
        // Aggregate byte-list init (`u8 a[N] = {…}`, `S s = {…}`):
        // element/field-wise stores. Handle before the scalar AddrOf so
        // no dead address is emitted.
        if (node.initialiser && node.initialiser.nodeKind == XTASTNodeKindBlock && node.declaredType && (node.declaredType.kind == XTTypeKindArray || node.declaredType.kind == XTTypeKindStruct))
            {
            [self lowerAggregateByteListInit:(XTBlockNode*)node.initialiser
                                      pinned:pl
                                    declType:node.declaredType
                                    location:node.location];
            return;
            }
        // Range-expression aggregate init (`u8 buf[N] = 0..10;` /
        // `1...5;` inclusive). Same element-wise-Store shape as the
        // byte-list array branch, with values generated from the
        // constant-folded bounds.
        if (node.initialiser && node.initialiser.nodeKind == XTASTNodeKindRangeExpr && node.declaredType && node.declaredType.kind == XTTypeKindArray)
            {
            [self lowerRangeArrayInit:(XTRangeExprNode*)node.initialiser
                               pinned:pl
                             declType:node.declaredType
                             location:node.location];
            return;
            }
        // Sized-scalar byte-list with non-constant entries (`float r =
        // {$00, $FF, m0, m1, m2}`): no single Const is possible, so emit
        // element-wise byte stores into the slot. The pre-scan pinned the
        // local precisely so this addressable storage exists. An all-
        // constant scalar byte-list stays on the Const fast path below.
        if (node.initialiser && node.initialiser.nodeKind == XTASTNodeKindBlock && [self scalarByteListStorableType:node.declaredType] && ![self byteListAllConstant:(XTBlockNode*)node.initialiser])
            {
            [self lowerScalarByteListStoresIntoPinned:(XTBlockNode*)node.initialiser
                                               pinned:pl
                                             declType:node.declaredType
                                             location:node.location];
            return;
            }
        // Weak local: the payload sits past two hidden link words. See pinnedAddr:.
        XTIRType* ptrTy = nil;
        XTIRValue* addr = [self pinnedAddr:pl name:node.varName outType:&ptrTy];
        if (!addr)
            return;
        XTIRValue* initVal = nil;
        if (node.initialiser && node.initialiser.nodeKind == XTASTNodeKindBlock)
            {
            initVal = [self lowerScalarByteListInit:(XTBlockNode*)node.initialiser
                                             toType:node.declaredType
                                           location:node.location];
            if (!initVal)
                return;
            }
        else if (node.initialiser)
            {
            initVal = [self lowerExpression:node.initialiser];
            if (!initVal)
                return;
            if (node.declaredType)
                {
                initVal = [self coerceValue:initVal
                                   fromType:node.initialiser.resolvedType
                                     toType:node.declaredType
                                   location:node.location];
                }
            }
        else
            {
            // Uninit scalar: store a Const #0 of the pinned type.
            initVal = [self allocateValueOfType:pl.type atSite:self.currentBlock];
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:initVal
                                                   operands:@[ [XTIROperand immIWithType:pl.type value:0] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:cz];
            }
        [self emitStore:addr value:initVal];
        // `S b = a;` copied a whole struct, link words and all, without linking
        // the destination — so the copy tested true after its referent died.
        [self relinkWeakSlotsAfterCopyAt:addr astType:node.declaredType];
        // Weak local (`weak:T@` or a `^`): register the slot so it auto-zeroes
        // when the target dies. Without this a `^` local is a silent
        // use-after-free — `if (a)` tests the code word, which stays valid.
        [self emitWeakLocalRegisterNamed:node.varName
                                   value:initVal
                                 rhsNode:node.initialiser];
        // A weak-class-pointer local does NOT own its referent. A +1 initialiser
        // (`new T`, a returnsRetained call — including a weak getter since 152)
        // was adopted by the store but nothing balanced it: the slot is only
        // UNREGISTERED at scope exit, never released, so the +1 leaked (bug 153).
        // Release it HERE, after the WeakRegister, so if this was the last strong
        // reference the auto-zero nils `w` — the defined weak semantics. A
        // borrowed initialiser owns nothing and must not be released.
        if ([self astTypeIsWeakClassPointer:node.declaredType] && node.initialiser && ![self arcRhsIsBorrowed:node.initialiser])
            [self emitRelease:initVal];
        return;
        }

    BOOL isStrong = [self astTypeIsClassPointer:node.declaredType];
    if (!node.initialiser)
        {
        // Uninitialised local: bind name to a Const 0 of the declared
        // type so subsequent reads work. Defensive — sema usually
        // enforces an initialiser. For class pointers we synthesise a
        // null-ptr constant so subsequent assignments can release-old
        // safely (Release of null is a runtime no-op).
        XTIRType* ty = [self irTypeForASTType:node.declaredType at:node.location];
        if (!ty)
            return;
        if (ty.kind == XTIRTypeKindPtr)
            {
            // Materialise a null pointer via Const #0:U16 + IntToPtr.
            XTIRValue* zero = [self allocateValueOfType:[XTIRType u16Type]
                                                 atSite:self.currentBlock];
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                                   value:0] ]
                                                     dbgLoc:nil];
            [self.currentBlock appendInstruction:cz];
            XTIRValue* np = [self emitInsnOpcode:XTIROpIntToPtr
                                          result:ty
                                        operands:@[ [XTIROperand useWithValueId:zero.valueId] ]];
            self.locals[node.varName] = np;
            }
        else
            {
            XTIRValue* r = [self allocateValueOfType:ty atSite:self.currentBlock];
            XTIRInsn* insn = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                       result:r
                                                     operands:@[ [XTIROperand immIWithType:ty value:0] ]
                                                       dbgLoc:nil];
            [self.currentBlock appendInstruction:insn];
            self.locals[node.varName] = r;
            }
        if (isStrong)
            {
            if (!self.strongLocals)
                self.strongLocals = [NSMutableSet set];
            [self.strongLocals addObject:node.varName];
            [self enrollInArcScope:node.varName];
            }
        return;
        }
    // Byte-list initialiser (`{ … }` / `[ … ]`, parsed as a block) for
    // a sized scalar: assemble the raw byte pattern into a Const.
    if (node.initialiser.nodeKind == XTASTNodeKindBlock)
        {
        XTIRValue* blv = [self lowerScalarByteListInit:(XTBlockNode*)node.initialiser
                                                toType:node.declaredType
                                              location:node.location];
        if (!blv)
            return;
        self.locals[node.varName] = blv;
        return;
        }

    XTIRBlock* exprStart = self.currentBlock; // full-expression boundary (#123)
    XTIRValue* initVal = [self lowerExpression:node.initialiser];
    if (!initVal)
        return;
    if (node.declaredType)
        {
        initVal = [self coerceValue:initVal
                           fromType:node.initialiser.resolvedType
                             toType:node.declaredType
                           location:node.location];
        }

    // ARC: strong-slot decl. Retain when the initialiser is a BORROWED
    // (+0) reference — an identifier / member-access / cast through a
    // class pointer, OR a call to a non-returnsRetained function (e.g.
    // Map.get); skip retain when it's value-producing (+1): `new T()` or
    // a returnsRetained call, whose owned temp the slot now adopts (#123).
    if (isStrong)
        {
        XTASTNode* init = node.initialiser;
        if ([self arcRhsIsBorrowed:init])
            {
            if ([self astTypeIsAnyClassPointer:init.resolvedType])
                [self emitRetain:initVal];
            }
        else
            {
            // +1 initialiser: the slot adopts the owned temp — don't let
            // the end-of-full-expression sweep release it too.
            [self consumeOwnedTemp:initVal];
            }
        if (!self.strongLocals)
            self.strongLocals = [NSMutableSet set];
        [self.strongLocals addObject:node.varName];
        [self enrollInArcScope:node.varName];
        }
    // The local now references initVal — adopt it so the sweep below won't
    // release it, even when the slot isn't a strong class pointer (e.g.
    // `Box b = new Box()` where `b` is declared `Box`, not `Box@`). For a
    // non-strong slot the worst case is a leak (safe), not a use-after-free
    // when the value is read on the next line (#123).
    [self consumeOwnedTemp:initVal];
    self.locals[node.varName] = initVal;
    // Release any other +1 temps produced by the initialiser (e.g. factory
    // calls passed as arguments) that weren't adopted by the slot.
    [self flushOwnedTempsFrom:exprStart];
    }

// main() always yields an exit code to the OS. A `void main` is normalised to
// `int main` in preScanFunction, so its IR return type is i32; every path that
// yields no value (a bare `return;` or fall-through) returns 0.
- (BOOL)isIntMain:(XTIRFunction*)fn
    {
    return fn && [fn.name isEqualToString:@"main"] && fn.returnType && fn.returnType.kind == XTIRTypeKindI32;
    }

// Materialise `(i32)0` in the current block for main's implicit exit code.
- (XTIRValue*)emitMainExitZero
    {
    XTIRValueId vid = [self.currentFunction allocateValueId];
    XTIRValue* zero = [[XTIRValue alloc] initWithValueId:vid
                                                    type:[XTIRType i32Type]
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:self.currentBlock insnIndex:0]];
    [self.currentFunction registerValue:zero];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:[XTIRType i32Type] value:0] ]
                                                     dbgLoc:nil]];
    return zero;
    }

- (void)lowerReturnStmt:(XTReturnNode*)node
    {
    NSMutableArray<XTIROperand*>* operands = [NSMutableArray array];
    // Multi-return: build an aggregate value and return it.
    if (node.values.count > 1)
        {
        XTIRType* retTy = self.currentFunction.returnType;
        if (retTy.kind != XTIRTypeKindAgg || !retTy.layout)
            {
            [self softFailLoweringAt:node.location
                         withMessage:@"lowering: multi-return but function return type is not aggregate"];
            return;
            }
        // Lower each return value and collect as AggBuild operands.
        XTIRBlock* exprStart = self.currentBlock;
        NSMutableArray<XTIRValue*>* retVals = [NSMutableArray array];
        for (XTASTNode* val in node.values)
            {
            XTIRValue* v = [self lowerExpression:val];
            if (!v)
                return;
            [retVals addObject:v];
            }
        // Same convention as the single-value path: every class pointer leaves
        // at +1, so a BORROWED element is retained before the teardown below
        // releases whatever owns it. `(T@, u16) f()` is rarer than the single
        // return, but a tuple element is no less able to be a container's.
        for (NSUInteger ri = 0; ri < retVals.count; ri++)
            {
            XTIRValue* rv = retVals[ri];
            BOOL owned = self.ownedTemps && [self.ownedTemps indexOfObjectIdenticalTo:rv] != NSNotFound;
            XTType* rvAST = ((XTASTNode*)node.values[ri]).resolvedType;
            // Weak-field reads count too (bug 036): a borrowed weak value returned
            // into an owned tuple element must be retained, not left at +0.
            if (!owned && [self irValueIsPointer:rv] && [self astTypeIsAnyClassPointer:rvAST] && ![self returnValueIsExemptStrongLocal:rv])
                {
                [self emitRetain:rv];
                }
            }
        // Returned values' +1 transfers to the caller; release other owned
        // temps the return expressions produced (#123).
        for (XTIRValue* rv in retVals)
            [self consumeOwnedTemp:rv];
        [self flushOwnedTempsFrom:exprStart];
        // Release strong locals, but skip the return-value locals
        // (ownership transfers to the caller).
        NSMutableSet<NSNumber*>* exemptIds = [NSMutableSet set];
        for (XTIRValue* rv in retVals)
            {
            [exemptIds addObject:@(rv.valueId)];
            }
        for (NSInteger si = (NSInteger)self.arcScopeStack.count - 1; si >= 0; si--)
            {
            NSMutableArray<NSString*>* frame = self.arcScopeStack[si];
            for (NSInteger i = (NSInteger)frame.count - 1; i >= 0; i--)
                {
                NSString* name = frame[i];
                if (self.strongArrayLocals[name])
                    {
                    [self emitStrongArrayReleaseForLocalNamed:name];
                    continue;
                    }
                if (self.weakArrayLocals[name])
                    {
                    [self emitWeakArrayUnregisterForLocalNamed:name];
                    continue;
                    }
                // A weak local (`weak:T@` or a bound method `^`) is linked into
                // its referent's weak chain so it auto-zeroes when the referent
                // dies. It is NOT owned, so there is nothing to release — but the
                // chain entry MUST come out, because the frame slot it points at
                // is about to be reused.
                //
                // popArcScopeEmittingReleases: does this. These two teardown
                // loops — the ones a `return` goes through — did not, so any
                // function that RETURNED while holding a `^` left a dead stack
                // slot on the receiver's weak list. The next time that receiver
                // was deallocated, the runtime walked the chain and wrote a zero
                // through the stale address. A comparator is exactly such a
                // function, which is how sorting an Array of Strings turned into
                // a SIGBUS inside _xtc_dealloc.
                if ([self.weakPinnedLocals containsObject:name])
                    {
                    [self emitWeakLocalUnregisterNamed:name];
                    continue;
                    }
                if (self.strongStructLocals[name])
                    {
                    if (![name isEqualToString:self.returnExemptStructName])
                        [self emitStructStrongFieldReleaseForLocalNamed:name];
                    continue;
                    }
                if (self.strongStructArrayLocals[name])
                    {
                    [self emitStructArrayARCForLocalNamed:name mode:XTStructARCRelease];
                    continue;
                    }
                XTIRValue* v = self.locals[name];
                if (!v)
                    continue;
                if ([exemptIds containsObject:@(v.valueId)])
                    continue;
                [self emitRelease:v];
                }
            }
        // Build the aggregate from the individual return values.
        XTIRValue* agg = [self allocateValueOfType:retTy atSite:self.currentBlock];
        NSMutableArray<XTIROperand*>* aggOps = [NSMutableArray array];
        for (XTIRValue* v in retVals)
            {
            [aggOps addObject:[XTIROperand useWithValueId:v.valueId]];
            }
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpAggBuild
                                                         result:agg
                                                       operands:aggOps
                                                         dbgLoc:nil]];
        // Emit Return with the aggregate value.
        [operands addObject:[XTIROperand useWithValueId:agg.valueId]];
        [operands addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
        [self emitTerminator:XTIROpReturn operands:operands];
        return;
        }
    // Lower the return value FIRST so it's live for use after the ARC
    // teardown emits Release for every strong-pointer local in scope.
    XTIRBlock* exprStart = self.currentBlock; // full-expression boundary (#123)
    XTIRValue* returnValue = nil;
    XTType* returnAstType = nil;
    if (node.values.count == 1)
        {
        returnValue = [self lowerExpression:node.values[0]];
        if (!returnValue)
            return;
        returnAstType = node.values[0].resolvedType;
        }
    // A BORROWED class pointer is retained before the teardown below runs.
    // Every class-pointer return is +1 (see astCallYieldsOwnedClassPointer),
    // and the value may be owned by something this function is about to
    // release — a local container, a strong local that is not the return
    // value, or a slot the caller lent us. Without the retain, the object can
    // reach refcount 0 between the teardown and the caller's first use.
    //
    // `return someStrongLocal;` does NOT come through here: the teardown
    // exempts that local by value, so its +1 moves to the caller as-is. Only a
    // genuinely borrowed expression pays the retain.
    BOOL returnIsOwnedTemp = returnValue && self.ownedTemps && [self.ownedTemps indexOfObjectIdenticalTo:returnValue] != NSNotFound;
    // A weak-field READ (`return weakField;`) is a borrowed value too, and the
    // return convention is +1 — so it must be retained exactly like a strong
    // borrowed read. astTypeIsClassPointer says NO to a weak pointer (a weak
    // SLOT must not be ARC'd), but the VALUE read out of it and returned into an
    // owned destination takes ownership. Using the strong-only predicate here
    // returned a weak field at +0, and the caller's release then freed a live
    // object — a getter of a `weak:` field killed it (bug 036 / uxkit 036).
    if (returnValue && !returnIsOwnedTemp && [self irValueIsPointer:returnValue] && [self astTypeIsAnyClassPointer:returnAstType] && ![self returnValueIsExemptStrongLocal:returnValue])
        {
        [self emitRetain:returnValue];
        }
    // The returned value's +1 (if it's an owned temp) transfers to the
    // caller — don't release it here; release any OTHER owned temps the
    // return expression produced (#123).
    [self consumeOwnedTemp:returnValue];
    [self flushOwnedTempsFrom:exprStart];
    // Release every strong-pointer local before emitting the
    // Return terminator. Skip the local that holds the return value
    // (the +1 ownership is transferred to the caller). If the value is a
    // struct LOCAL, exempt it by name too — its strong fields' +1 transfers
    // to the caller via sret (a move), so the teardown must not free them.
    self.returnExemptStructName = nil;
    if (node.values.count == 1 && node.values[0].nodeKind == XTASTNodeKindIdentifier)
        {
        NSString* rn = ((XTIdentifierNode*)node.values[0]).identName;
        if (self.strongStructLocals[rn])
            self.returnExemptStructName = rn;
        }
    // `return outer.inner;` — the returned sub-struct is PROJECTED out of a
    // containing local (a member-access, not a bare identifier), so the local
    // is NOT exempt and its scope-exit teardown will Release the projected
    // strong fields (e.g. outer.inner.payload). That would free them out from
    // under the caller. Retain the source's strong fields FIRST so the +1
    // transfers to the caller and the teardown's Release balances back to the
    // pre-return refcount. (A bare-identifier struct return is an exempt move,
    // handled above; only the projection path needs the explicit retain.)
    if (node.values.count == 1 && node.values[0].nodeKind == XTASTNodeKindMemberAccess && [returnAstType isKindOfClass:[XTStructType class]] && [self astTypeOwnsClassPointer:returnAstType])
        {
        XTIRValue* srcAddr = [self addressOfStructLValue:node.values[0]];
        if (srcAddr)
            [self emitStructStrongFieldRetainAt:srcAddr structType:(XTStructType*)returnAstType];
        }
    [self releaseStrongLocalsAlongReturnExcept:returnValue];
    self.returnExemptStructName = nil;
    if (returnValue)
        {
        XTIRValue* v = returnValue;
        // Coerce to the function's return type if the value's type
        // differs.
        XTType* srcAST = returnAstType;
        XTIRType* dstIR = self.currentFunction.returnType;
        if (srcAST && dstIR && dstIR.kind != XTIRTypeKindVoid)
            {
            BOOL srcFloat = v.type && XTIRTypeKindIsFloating(v.type.kind);
            BOOL dstFloat = XTIRTypeKindIsFloating(dstIR.kind);
            // Pointer returns: the value is already a Ptr (backend-
            // native width). The shared AST pointer byteWidth (2, Atari)
            // differs from the IR Ptr byteWidth (0), so the integer
            // path below would emit a bogus Trunc — corrupting the
            // returned pointer (on arm64 it truncates a 64-bit host
            // pointer to 32 bits). Both-pointer → return as-is.
            BOOL srcPtr = v.type && v.type.kind == XTIRTypeKindPtr;
            BOOL dstPtr = dstIR.kind == XTIRTypeKindPtr;
            // `@`→`^` widening in a RETURN: `return &freeFunction;` from a
            // function whose return type is a callback. The cascade below is
            // integer / float / pointer coercion and an Agg destination fits
            // none of them, so the widened function fell into the INTEGER
            // path: the code address was truncated to the aggregate's width
            // and the receiver word was never written at all. It crashed at
            // the call, at every -O level (private:docs/bugs/075).
            //
            // The other two sites that can see this conversion already widen —
            // widenBoundArgAt for call arguments, coerceValueImpl for value
            // contexts. Returns are the third, and had no case. Returning an
            // already-widened `^` is unaffected: fnSignatureForWidening
            // returns nil for a value that is already one.
            XTFunctionType* bmSig = (dstIR.kind == XTIRTypeKindAgg)
                                        ? [self fnSignatureForWidening:srcAST]
                                        : nil;
            if (bmSig)
                {
                XTIRValue* w = [self widenFunctionPointer:v
                                                signature:bmSig
                                                toAggType:dstIR];
                if (w)
                    v = w;
                }
            else if (srcPtr && dstPtr)
                {
                // identical representation — no coercion.
                }
            else if (srcFloat || dstFloat)
                {
                // Float-aware coercion — keyed off IR types so a
                // float's backend-neutral IR width doesn't trigger a
                // bogus integer Trunc/Ext.
                XTIROpcode fop = XTIROpBitcast;
                BOOL needed = YES;
                if (srcFloat && dstFloat)
                    {
                    if (dstIR.byteWidth > v.type.byteWidth)
                        fop = XTIROpFpExt;
                    else if (dstIR.byteWidth < v.type.byteWidth)
                        fop = XTIROpFpTrunc;
                    else
                        needed = NO; // same precision — no-op
                    }
                else if (dstFloat)
                    {
                    fop = srcAST.isSigned ? XTIROpSIToFp : XTIROpUIToFp;
                    }
                else
                    {
                    fop = XTIRTypeKindIsSigned(dstIR.kind) ? XTIROpFpToSI : XTIROpFpToUI;
                    }
                if (needed)
                    {
                    v = [self emitInsnOpcode:fop
                                      result:dstIR
                                    operands:@[ [XTIROperand useWithValueId:v.valueId] ]];
                    if (!v)
                        return;
                    }
                }
            else
                {
                NSUInteger srcW = srcAST.byteWidth;
                NSUInteger dstW = dstIR.byteWidth;
                BOOL srcSgn = srcAST.isSigned;
                BOOL dstSgn = XTIRTypeKindIsSigned(dstIR.kind);
                if (srcW != dstW || srcSgn != dstSgn)
                    {
                    XTIROpcode op;
                    if (dstW > srcW)
                        op = srcSgn ? XTIROpSExt : XTIROpZExt;
                    else if (dstW < srcW)
                        op = XTIROpTrunc;
                    else
                        op = XTIROpBitcast;
                    v = [self emitInsnOpcode:op
                                      result:dstIR
                                    operands:@[ [XTIROperand useWithValueId:v.valueId] ]];
                    if (!v)
                        return;
                    }
                }
            }
        [operands addObject:[XTIROperand useWithValueId:v.valueId]];
        }
    // A bare `return;` inside main() yields the exit code 0 (main is int).
    if (operands.count == 0 && [self isIntMain:self.currentFunction])
        {
        XTIRValue* z = [self emitMainExitZero];
        [operands addObject:[XTIROperand useWithValueId:z.valueId]];
        }
    [operands addObject:[XTIROperand useWithValueId:self.memToken.valueId]];
    [self emitTerminator:XTIROpReturn operands:operands];
    }

- (void)lowerExprStmt:(XTExpressionStatementNode*)node
    {
    XTIRBlock* exprStart = self.currentBlock;
    (void)[self lowerExpression:node.expression];
    // Release +1 owned temps produced by this full-expression that no
    // strong binding adopted — the arg-temp leak fix (#123): e.g.
    // `m.set(Number.withU16(i), v)` / a bare `m.get(Number.withU16(i));`.
    [self flushOwnedTempsFrom:exprStart];
    }

#pragma mark - Control flow (if / while)

// A snapshot of the per-local SSA bindings at a given block-exit
// point. The merge routine reads two such snapshots and builds the
// phi nodes for the join block.
typedef NSDictionary<NSString*, XTIRValue*> XTIRLocalSnapshot;

- (XTIRLocalSnapshot*)snapshotLocals
    {
    return [self.locals copy];
    }

// Replace `self.locals` with the snapshot.
- (void)restoreLocals:(XTIRLocalSnapshot*)snap
    {
    self.locals = [snap mutableCopy];
    }

// Given two predecessor snapshots and a join block, emit a phi for
// every local whose value differs between the snapshots. Updates
// self.locals to the post-merge values.
/****************************************************************************\
|* Merge N predecessor snapshots into `joinBlock`.
|*
|* The two-way form below is this with two entries; `if`/`else` therefore keeps
|* byte-identical output. A `try` needs the general one: its join is reached
|* from the guarded block, from every catch arm, and from the no-arm-matched
|* edge — at least three predecessors, which is why it merged NOTHING before
|* (private:docs/bugs/052) and `try { v = f(); } catch { v = d; }` lost both values.
|*
|* `base` is the binding set BEFORE the region. Every edge into the join
|* descends from it, so every name in `base` has a value on each edge — which is
|* what makes an N-way phi well-formed. A name introduced INSIDE the region is
|* out of scope after it and is dropped rather than merged.
|*
|* @param joinBlock  The block the edges converge on.
|* @param snaps      One local snapshot per incoming edge.
|* @param blocks     The predecessor block of each snapshot, same order.
|* @param base       Bindings live before the region; the default per edge.
\****************************************************************************/
- (void)mergeAtJoin:(XTIRBlock*)joinBlock
          snapshots:(NSArray<XTIRLocalSnapshot*>*)snaps
      throughBlocks:(NSArray<XTIRBlock*>*)blocks
               base:(XTIRLocalSnapshot*)base
    {
    if (snaps.count != blocks.count || snaps.count == 0)
        return;
    NSMutableDictionary<NSString*, XTIRValue*>* merged = [base mutableCopy];
    // SORTED, for the reason the loop lowerings sort their assigned-locals
    // scan: an NSSet/NSDictionary iterates in hash order, and the phi ORDER at
    // a join is printed in the IR text. Leaving it to the hash makes the output
    // unpredictable from the input and unreproducible by a second
    // implementation of the same lowering.
    for (NSString* name in [base.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        XTIRValue* first = nil;
        BOOL allSame = YES, anyMissing = NO;
        NSMutableArray<XTIRValue*>* perEdge = [NSMutableArray array];
        for (XTIRLocalSnapshot* sn in snaps)
            {
            XTIRValue* v = sn[name] ?: base[name];
            if (!v)
                {
                anyMissing = YES;
                break;
                }
            [perEdge addObject:v];
            if (!first)
                first = v;
            else if (v != first)
                allSame = NO;
            }
        if (anyMissing || allSame)
            continue; // `merged` already holds base/first

        // Phi operands follow each predecessor's index in fn.blocks — the
        // verifier's §12.4 check walks preds in source-block iteration order,
        // so the phi's operand order has to match.
        NSMutableArray<NSNumber*>* order = [NSMutableArray array];
        for (NSUInteger i = 0; i < blocks.count; i++)
            [order addObject:@(i)];
        [order sortUsingComparator:^NSComparisonResult(NSNumber* x, NSNumber* y) {
          NSUInteger ix = [self.currentFunction.blocks
              indexOfObjectIdenticalTo:blocks[x.unsignedIntegerValue]];
          NSUInteger iy = [self.currentFunction.blocks
              indexOfObjectIdenticalTo:blocks[y.unsignedIntegerValue]];
          if (ix < iy)
              return NSOrderedAscending;
          if (ix > iy)
              return NSOrderedDescending;
          return NSOrderedSame;
        }];

        XTIRValueId vid = [self.currentFunction allocateValueId];
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:joinBlock insnIndex:0];
        XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid
                                                             type:first.type
                                                          defSite:site];
        [self.currentFunction registerValue:phiResult];
        NSMutableArray<XTIROperand*>* operands = [NSMutableArray array];
        for (NSNumber* idx in order)
            {
            NSUInteger i = idx.unsignedIntegerValue;
            [operands addObject:[XTIROperand blockWithRef:blocks[i]]];
            [operands addObject:[XTIROperand useWithValueId:perEdge[i].valueId]];
            }
        [joinBlock.phiNodes addObject:[[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                                result:phiResult
                                                              operands:operands
                                                                dbgLoc:nil]];
        merged[name] = phiResult;
        }
    self.locals = merged;
    }

- (void)mergeAtJoin:(XTIRBlock*)joinBlock
              fromA:(XTIRLocalSnapshot*)snapA
       throughBlock:(XTIRBlock*)blockA
              fromB:(XTIRLocalSnapshot*)snapB
       throughBlock:(XTIRBlock*)blockB
               base:(XTIRLocalSnapshot*)base
    {
    // Only the names bound BEFORE the region, as the N-way merge above already
    // does. This walked the UNION of both arms' names, so a local declared
    // inside an arm — out of scope at the join — was merged anyway: two
    // sibling-scope locals both named `bits`, one u64 and one u32, became one
    // dead phi of type U64 fed a U32, and wasm32 refused the module
    // (private:docs/bugs/132). A name absent from `base` is dropped here, which is
    // what going out of scope means.
    NSMutableDictionary<NSString*, XTIRValue*>* merged = [NSMutableDictionary dictionary];
    // SORTED, for the reason the loop lowerings sort their assigned-locals
    // scan: a dictionary iterates in hash order, and the phi ORDER at a join
    // is printed in the IR text. Leaving it to the hash makes the output
    // unpredictable from the input and unreproducible by a second
    // implementation of the same lowering.
    for (NSString* name in [base.allKeys sortedArrayUsingSelector:@selector(compare:)])
        {
        XTIRValue* vA = snapA[name] ?: base[name];
        XTIRValue* vB = snapB[name] ?: base[name];
        if (vA == vB)
            {
            merged[name] = vA;
            }
        else if (vA && vB)
            {
            // Insert a phi.
            XTIRType* ty = vA.type;
            XTIRValueId vid = [self.currentFunction allocateValueId];
            XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:joinBlock insnIndex:0];
            XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:ty defSite:site];
            [self.currentFunction registerValue:phiResult];
            // Order the phi pairs by each predecessor's index in
            // fn.blocks — the verifier's §12.4 check walks preds in
            // source-block iteration order, and the phi's operand
            // order has to match. The naive (blockA, blockB) order
            // is wrong for no-else ifs where elseExit (the
            // predBlock, earlier in fn.blocks) needs to come first.
            NSUInteger idxA = [self.currentFunction.blocks indexOfObjectIdenticalTo:blockA];
            NSUInteger idxB = [self.currentFunction.blocks indexOfObjectIdenticalTo:blockB];
            XTIRBlock* firstBlock = (idxA <= idxB) ? blockA : blockB;
            XTIRBlock* secondBlock = (idxA <= idxB) ? blockB : blockA;
            XTIRValue* firstValue = (idxA <= idxB) ? vA : vB;
            XTIRValue* secondValue = (idxA <= idxB) ? vB : vA;
            NSArray<XTIROperand*>* operands = @[
                [XTIROperand blockWithRef:firstBlock],
                [XTIROperand useWithValueId:firstValue.valueId],
                [XTIROperand blockWithRef:secondBlock],
                [XTIROperand useWithValueId:secondValue.valueId],
            ];
            XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                      result:phiResult
                                                    operands:operands
                                                      dbgLoc:nil];
            [joinBlock.phiNodes addObject:phi];
            merged[name] = phiResult;
            }
        else
            {
            // Only one branch defines it — keep the defined one. The
            // verifier won't complain because the absent branch never
            // referenced it.
            merged[name] = vA ?: vB;
            }
        }
    self.locals = merged;
    }

- (XTIRBlock*)addBlockWithName:(NSString*)name
    {
    XTIRBlock* b = [[XTIRBlock alloc] init];
    b.name = name;
    [self.currentFunction.blocks addObject:b];
    return b;
    }

// `cond ? then : else` — a value-producing conditional. Mirrors the
// if-statement block shape (then / else / join) but each arm yields a
// value; a phi at the join merges them into the expression's result.
// Locals mutated inside an arm are merged via the same mergeAtJoin:
// machinery the if-statement uses.
/****************************************************************************\
|* The short name of an IR type kind, for a diagnostic. Deliberately the KIND
|* and not the full type: what this reports is a kind mismatch.
|* @param k  The type kind.
|* @return   Its spelling in IR text.
\****************************************************************************/
static NSString* XTIRTypeKindName(XTIRTypeKind k)
    {
    switch (k)
        {
    case XTIRTypeKindVoid:
        return @"Void";
    case XTIRTypeKindI8:
        return @"I8";
    case XTIRTypeKindU8:
        return @"U8";
    case XTIRTypeKindI16:
        return @"I16";
    case XTIRTypeKindU16:
        return @"U16";
    case XTIRTypeKindI32:
        return @"I32";
    case XTIRTypeKindU32:
        return @"U32";
    case XTIRTypeKindI64:
        return @"I64";
    case XTIRTypeKindU64:
        return @"U64";
    case XTIRTypeKindF32:
        return @"F32";
    case XTIRTypeKindF64:
        return @"F64";
    case XTIRTypeKindBool:
        return @"Bool";
    case XTIRTypeKindPtr:
        return @"Ptr";
    case XTIRTypeKindAgg:
        return @"Agg";
    case XTIRTypeKindMemory:
        return @"Memory";
    case XTIRTypeKindVec:
        return @"Vec";
        }
    return @"?";
    }

/****************************************************************************\
|* One incoming of a phi must have the phi's own type. See the call site in
|* lowerTernaryExpr: (bug 092) for why this is worth a check rather than a
|* comment.
|* @param res  The phi's result value.
|* @param v    One incoming value.
|* @param at   The AST node the incoming came from — the reported location.
\****************************************************************************/
- (void)checkPhiIncoming:(XTIRValue*)res
                   value:(XTIRValue*)v
                      at:(XTASTNode*)at
    {
    if (!res || !v || !res.type || !v.type)
        return;
    // KIND, not identity: two Ptr types with different pointees are the same
    // machine value and reach a phi legitimately, so comparing whole types
    // would reject working code. What cannot be merged is a Bool where an I64
    // is expected, or an F32 where a Ptr is — a difference of kind.
    if (res.type.kind == v.type.kind)
        return;
    [self softFailLoweringAt:(at ? at.location : nil)
                 withMessage:[NSString stringWithFormat:
                                           @"internal: this expression's branches produce different types (%@ and "
                                           @"%@) - the two would meet in a value that cannot hold both",
                                           XTIRTypeKindName(res.type.kind), XTIRTypeKindName(v.type.kind)]];
    }

- (nullable XTIRValue*)lowerTernaryExpr:(XTTernaryExprNode*)node
    {
    XTIRValue* cond = [self lowerConditionExpr:node.condition];
    if (!cond)
        return nil;

    XTIRType* resultIR = [self irTypeForASTType:node.resolvedType at:node.location];
    if (!resultIR)
        return nil;

    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* thenBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_tern_then"]];
    XTIRBlock* elseBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_tern_else"]];
    XTIRBlock* joinBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_tern_join"]];

    XTIRLocalSnapshot* entrySnap = [self snapshotLocals];
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cond.valueId],
                            [XTIROperand blockWithRef:thenBlock],
                            [XTIROperand blockWithRef:elseBlock] ]];

    // THEN arm. Inside an arm, a `+1` temp is CONDITIONAL — live on this path
    // only — so bump condDepth; the end-of-full-expression sweep will not
    // release a temp born here (see flushOwnedTempsFrom).
    self.condDepth += 1;
    self.currentBlock = thenBlock;
    [self restoreLocals:entrySnap];
    XTIRValue* thenVal = [self lowerExpression:node.thenExpr];
    if (!thenVal)
        {
        self.condDepth -= 1;
        return nil;
        }
    thenVal = [self coerceValue:thenVal
                       fromType:node.thenExpr.resolvedType
                         toType:node.resolvedType
                       location:node.location];
    if (!thenVal)
        {
        self.condDepth -= 1;
        return nil;
        }
    XTIRBlock* thenExit = self.currentBlock;
    XTIRLocalSnapshot* thenSnap = [self snapshotLocals];
    // The branch is NOT emitted yet. Ownership of the arms cannot be settled
    // until both are lowered, and balancing a mixed pair means emitting a
    // Retain INTO an arm's block — which has to happen before its terminator.
    // See the ownership block below (private:docs/bugs/081).

    // ELSE arm.
    self.currentBlock = elseBlock;
    [self restoreLocals:entrySnap];
    XTIRValue* elseVal = [self lowerExpression:node.elseExpr];
    if (!elseVal)
        {
        self.condDepth -= 1;
        return nil;
        }
    elseVal = [self coerceValue:elseVal
                       fromType:node.elseExpr.resolvedType
                         toType:node.resolvedType
                       location:node.location];
    if (!elseVal)
        {
        self.condDepth -= 1;
        return nil;
        }
    XTIRBlock* elseExit = self.currentBlock;
    XTIRLocalSnapshot* elseSnap = [self snapshotLocals];

    // OWNERSHIP OF THE ARMS (private:docs/bugs/081, found by blewit leaking).
    //
    // An arm that produced a +1 temp registered it at the ARM's conditional
    // depth, and the end-of-full-expression sweep only releases temps recorded
    // at the current depth — rightly, since at the join it cannot know which
    // arm ran. So nobody released it, and arcRhsIsBorrowed called the whole
    // ternary borrowed, so the binding retained on top: every evaluation of
    // `p = c ? new P() : new P()` leaked the object outright.
    //
    // The result becomes the owned thing. Each arm's temp stops being pending
    // and the phi is registered at the OUTER depth, where the enclosing
    // statement (or a binding that adopts it) can see it.
    //
    // A MIXED pair — one arm +1, one borrowed — is balanced by retaining the
    // borrowed side in its own block, so the join is +1 whichever way control
    // went and the single release is correct either way. That is why
    // arcRhsIsBorrowed says EITHER arm rather than both; the two rules have to
    // agree or the binding adopts a value that is only sometimes owned.
    BOOL thenOwned = [self.ownedTemps indexOfObjectIdenticalTo:thenVal] != NSNotFound;
    BOOL elseOwned = [self.ownedTemps indexOfObjectIdenticalTo:elseVal] != NSNotFound;
    BOOL armOwned = (thenOwned || elseOwned) && [self astTypeIsClassPointer:node.resolvedType];
    if (armOwned)
        {
        if (thenOwned)
            {
            [self consumeOwnedTemp:thenVal];
            }
        else
            {
            self.currentBlock = thenExit;
            [self emitRetain:thenVal];
            }
        if (elseOwned)
            {
            [self consumeOwnedTemp:elseVal];
            }
        else
            {
            self.currentBlock = elseExit;
            [self emitRetain:elseVal];
            }
        }

    self.currentBlock = thenExit;
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
    self.currentBlock = elseExit;
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
    self.condDepth -= 1; // back out to the enclosing region

    // JOIN: merge mutated locals, then phi the arm result values. Phi
    // operand order follows fn.blocks index (verifier §12.4), matching
    // mergeAtJoin:.
    self.currentBlock = joinBlock;
    [self mergeAtJoin:joinBlock
                fromA:thenSnap
         throughBlock:thenExit
                fromB:elseSnap
         throughBlock:elseExit
                 base:entrySnap];

    XTIRValueId vid = [self.currentFunction allocateValueId];
    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:joinBlock insnIndex:0];
    XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:resultIR defSite:site];
    [self.currentFunction registerValue:phiResult];
    NSUInteger idxThen = [self.currentFunction.blocks indexOfObjectIdenticalTo:thenExit];
    NSUInteger idxElse = [self.currentFunction.blocks indexOfObjectIdenticalTo:elseExit];
    XTIRBlock* firstB = (idxThen <= idxElse) ? thenExit : elseExit;
    XTIRBlock* secondB = (idxThen <= idxElse) ? elseExit : thenExit;
    XTIRValue* firstV = (idxThen <= idxElse) ? thenVal : elseVal;
    XTIRValue* secondV = (idxThen <= idxElse) ? elseVal : thenVal;
    XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                              result:phiResult
                                            operands:@[
                                                [XTIROperand blockWithRef:firstB],
                                                [XTIROperand useWithValueId:firstV.valueId],
                                                [XTIROperand blockWithRef:secondB],
                                                [XTIROperand useWithValueId:secondV.valueId],
                                            ]
                                              dbgLoc:nil];
    // A phi's incomings must ALL have the phi's own type. When they do not the
    // IR is malformed on every target — but a machine with untyped registers
    // runs it anyway, so the mismatch survives codegen and surfaces as a wasm
    // module that will not instantiate, reported by a validator against a whole
    // FUNCTION, which is nothing to bisect towards. That was bug 092: sema
    // typed a comparison as its operands, a ternary unioned it with a bool arm,
    // and the arm that already believed it was i64 was never widened. Refusing
    // here turns the same mistake into a compile error at the arm's line.
    [self checkPhiIncoming:phiResult value:thenVal at:node.thenExpr];
    [self checkPhiIncoming:phiResult value:elseVal at:node.elseExpr];
    [joinBlock.phiNodes addObject:phi];
    // Registered HERE, at the OUTER depth, so the enclosing full-expression's
    // sweep can release it — or a binding can adopt it and consume the
    // registration. Without this the arms' ownership was consumed and handed
    // to nobody, which leaks a ternary used as a call ARGUMENT (private:docs/bugs/081
    // case D) even once the binding case is right.
    if (armOwned)
        [self registerOwnedTemp:phiResult];
    return phiResult;
    }

// Short-circuit `a && b` / `a || b`. Lowers to a branch on the LHS,
// an RHS-evaluation block reached only when the result isn't already
// decided, and a join whose phi merges the short-circuit constant
// (false for &&, true for ||) with the RHS value. Side effects in the
// RHS therefore run only on the live path, and arm-mutated locals are
// merged via mergeAtJoin:. Result is a Bool.
- (nullable XTIRValue*)lowerShortCircuit:(XTBinaryExprNode*)node
    {
    BOOL isAnd = (node.op == XTBinaryOpLogAnd);
    XTIRType* boolTy = [XTIRType boolType];

    XTIRValue* lhs = [self lowerExpression:node.left];
    if (!lhs)
        return nil;

    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* rhsBlock = [self addBlockWithName:
                                    [prefix stringByAppendingString:(isAnd ? @"_and_rhs" : @"_or_rhs")]];
    XTIRBlock* joinBlock = [self addBlockWithName:
                                     [prefix stringByAppendingString:(isAnd ? @"_and_join" : @"_or_join")]];

    XTIRBlock* predBlock = self.currentBlock;
    XTIRLocalSnapshot* entrySnap = [self snapshotLocals];

    // Short-circuit constant, materialised in predBlock so it's live
    // on the pred→join edge: && yields 0 when the LHS is false, ||
    // yields 1 when the LHS is true.
    XTIRValue* shortVal = [self allocateValueOfType:boolTy atSite:predBlock];
    [predBlock appendInstruction:[[XTIRInsn alloc]
                                     initWithOpcode:XTIROpConst
                                             result:shortVal
                                           operands:@[ [XTIROperand immIWithType:boolTy value:(isAnd ? 0 : 1)] ]
                                             dbgLoc:nil]];

    // && : LHS true → eval RHS ; false → join(0).
    // || : LHS true → join(1) ; false → eval RHS.
    XTIRBlock* trueTarget = isAnd ? rhsBlock : joinBlock;
    XTIRBlock* falseTarget = isAnd ? joinBlock : rhsBlock;
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:lhs.valueId],
                            [XTIROperand blockWithRef:trueTarget],
                            [XTIROperand blockWithRef:falseTarget] ]];

    // RHS block — only reached when the LHS didn't decide the result. It is a
    // conditional arm, so a `+1` temp born here is not live at the join; bump
    // condDepth for the same reason the ternary arms do.
    self.condDepth += 1;
    self.currentBlock = rhsBlock;
    [self restoreLocals:entrySnap];
    XTIRValue* rhs = [self lowerExpression:node.right];
    if (!rhs)
        {
        self.condDepth -= 1;
        return nil;
        }
    rhs = [self coerceValue:rhs
                   fromType:node.right.resolvedType
                     toType:[XTType boolType]
                   location:node.location];
    if (!rhs)
        {
        self.condDepth -= 1;
        return nil;
        }
    // Release the `+1` temps born in THIS arm before leaving it. They are live
    // on this path only, and a short-circuit arm's value is a Bool — so unlike
    // a ternary arm, none of them can BE the result, and releasing here is
    // unambiguous. Without it they leak, and the runtime's refcount is a u16
    // that WRAPS: the same object leaked ~65,536 times reaches 0 and the next
    // release frees it while it is still owned (private:docs/bugs/025 — a
    // 1,300-function module reaches that in one run).
    [self releaseOwnedTempsAtDepth:self.condDepth];
    XTIRBlock* rhsExit = self.currentBlock;
    XTIRLocalSnapshot* rhsSnap = [self snapshotLocals];
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
    self.condDepth -= 1;

    // JOIN: merge mutated locals, then phi the result. Operand order
    // follows fn.blocks index (verifier §12.4), as in mergeAtJoin:.
    self.currentBlock = joinBlock;
    [self mergeAtJoin:joinBlock
                fromA:entrySnap
         throughBlock:predBlock
                fromB:rhsSnap
         throughBlock:rhsExit
                 base:entrySnap];

    XTIRValueId vid = [self.currentFunction allocateValueId];
    XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:joinBlock insnIndex:0];
    XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:boolTy defSite:site];
    [self.currentFunction registerValue:phiResult];
    NSUInteger idxPred = [self.currentFunction.blocks indexOfObjectIdenticalTo:predBlock];
    NSUInteger idxRhs = [self.currentFunction.blocks indexOfObjectIdenticalTo:rhsExit];
    XTIRBlock* firstB = (idxPred <= idxRhs) ? predBlock : rhsExit;
    XTIRBlock* secondB = (idxPred <= idxRhs) ? rhsExit : predBlock;
    XTIRValue* firstV = (idxPred <= idxRhs) ? shortVal : rhs;
    XTIRValue* secondV = (idxPred <= idxRhs) ? rhs : shortVal;
    XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                              result:phiResult
                                            operands:@[
                                                [XTIROperand blockWithRef:firstB],
                                                [XTIROperand useWithValueId:firstV.valueId],
                                                [XTIROperand blockWithRef:secondB],
                                                [XTIROperand useWithValueId:secondV.valueId],
                                            ]
                                              dbgLoc:nil];
    [joinBlock.phiNodes addObject:phi];
    return phiResult;
    }

/****************************************************************************\
|* Lower an expression used as a BOOLEAN condition.
|*
|* Identical to lowerExpression: except for a bound method (`^`), which is a
|* 2-word aggregate and can't be branched on directly. A `^` tests its CODE
|* word — deliberately not `recv`:
|*
|*   - `&obj.m` on a null receiver, or on an unimplemented `optional` method,
|*     has code == 0 → falsy. So one `if (h)` covers both "no delegate" and
|*     "delegate doesn't implement it", and `if (h)` IS respondsTo.
|*   - a free function widened to `^` legitimately has recv == 0 but a real
|*     code word → truthy.
|*
|* Testing `recv` would get the second case backwards. See
|* private:docs/Design/bound-methods.md.
\****************************************************************************/
- (XTIRValue*)lowerConditionExpr:(XTASTNode*)e
    {
    XTIRValue* v = [self lowerExpression:e];
    if (!v)
        return nil;
    XTType* t = e.resolvedType;
    // The AST type is not enough on its own. sema types a comparison as the
    // WIDENING OF ITS OPERANDS, not as bool — so `f == (Sink^)0` is itself
    // typed `^`, while the value just lowered is the Bool the comparison
    // produced. Extracting field 0 from that Bool yielded a garbage condition:
    // on win64 `f == 0` and `f != 0` were BOTH true, so every
    // `if (cb == 0) return;` guard took the early return and every optional
    // callback silently did nothing. arm64 happened to tolerate the bad
    // instruction, which is why it only showed up on one target.
    //
    // So the test is what we ACTUALLY have in hand: extract only from a real
    // aggregate.
    BOOL haveAggregate = v.type && v.type.kind == XTIRTypeKindAgg;
    if (t && t.boundMethodSignature != nil && haveAggregate)
        {
        // Tests the RECV word (field 0). Every case works:
        //
        //   bound, alive        recv = obj      -> true
        //   bound, target died  recv = 0        -> false   (weak-zeroed)
        //   optional, absent    recv forced 0   -> false   (see lowerBoundMethodRef)
        //   null receiver       recv = 0        -> false
        //   widened function    recv = fn ptr   -> true    (a .text addr; never dies)
        //
        // It used to test CODE, which forced the weak runtime to zero TWO words
        // for a `^` but ONE for a `weak:T@` — an asymmetry that would need a
        // kind-tag in every side-table node. Testing recv makes the node uniform:
        // zero word 0, whatever the slot holds.
        XTIRType* ptrT = [XTIRType ptrToType:[XTIRType voidType]
                                      window:XTIRWindowUnbanked];
        v = [self emitInsnOpcode:XTIROpAggExtract
                          result:ptrT
                        operands:@[ [XTIROperand useWithValueId:v.valueId],
                                    [XTIROperand immIWithType:[XTIRType u16Type]
                                                        value:0] ]];
        }
    return v;
    }

- (void)lowerIfStmt:(XTIfNode*)node
    {
    XTIRBlock* condStart = self.currentBlock;
    XTIRValue* cond = [self lowerConditionExpr:node.condition];
    if (!cond)
        return;
    // A CONDITION is a full expression, so any +1 temporary it produced is
    // released here — before the branch, on the single path where it was
    // created. Nothing did this, so `if (list.get(0) != 0)` leaked the object
    // it tested: harmless while a +0 convention meant conditions rarely held a
    // +1, and a leak per test the moment every class-pointer return became +1.
    [self flushOwnedTempsFrom:condStart];

    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* thenBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_then"]];
    XTIRBlock* elseBlock = node.elseBlock
                               ? [self addBlockWithName:[prefix stringByAppendingString:@"_else"]]
                               : nil;
    XTIRBlock* joinBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_join"]];

    XTIRBlock* predBlock = self.currentBlock;
    XTIRLocalSnapshot* entrySnap = [self snapshotLocals];

    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cond.valueId],
                            [XTIROperand blockWithRef:thenBlock],
                            [XTIROperand blockWithRef:elseBlock ?: joinBlock] ]];

    // THEN branch.
    self.currentBlock = thenBlock;
    [self restoreLocals:entrySnap];
    [self lowerStatement:node.thenBlock];
    if (self.aborted)
        return;
    XTIRBlock* thenExit = self.currentBlock;
    // An arm reaches the join only if it fell through. If it already
    // self-terminated — `return`, or a `break`/`continue` that
    // branched to the loop exit/header — it is NOT a join predecessor,
    // so it contributes no phi operand there.
    XTIRLocalSnapshot* thenSnap = nil;
    if (!thenExit.terminator)
        {
        thenSnap = [self snapshotLocals];
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
        }

    // ELSE branch (or fall-through equivalent).
    XTIRLocalSnapshot* elseSnap = nil;
    XTIRBlock* elseExit = nil;
    if (elseBlock)
        {
        self.currentBlock = elseBlock;
        [self restoreLocals:entrySnap];
        [self lowerStatement:node.elseBlock];
        if (self.aborted)
            return;
        elseExit = self.currentBlock;
        if (!elseExit.terminator)
            {
            elseSnap = [self snapshotLocals];
            [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:joinBlock] ]];
            }
        }
    else
        {
        // No else: the fall-through edge into joinBlock carries the
        // entry snapshot (no statements executed on this side).
        elseSnap = entrySnap;
        elseExit = predBlock;
        }

    // Merge.
    self.currentBlock = joinBlock;
    if (thenSnap && elseSnap)
        {
        [self mergeAtJoin:joinBlock
                    fromA:thenSnap
             throughBlock:thenExit
                    fromB:elseSnap
             throughBlock:elseExit
                     base:entrySnap];
        }
    else if (thenSnap)
        {
        [self restoreLocals:thenSnap];
        }
    else if (elseSnap)
        {
        [self restoreLocals:elseSnap];
        }
    else
        {
        // Both arms diverged (`return` on each side), so NOTHING branches to the join:
        // it is unreachable from entry, the verifier rejects it (§12.10), and the module
        // is thrown out. Which meant this — as ordinary as code gets — did not compile:
        //
        //     i16 pick(bool c, i16 a, i16 b) { if (c) { return a; } else { return b; } }
        //
        // The old comment said "the verifier's §12.10 will flag it. Leave it." — and it
        // did flag it, and the build failed. Drop the block instead: it has no
        // predecessors, so there is nothing to emit and nothing to jump to.
        //
        // Terminate it with Unreachable and KEEP it. Removing it from fn.blocks instead
        // orphans self.currentBlock, and a nested `if` then reports its (orphaned) join
        // as a live exit to the enclosing arm — which just moves the unreachable block
        // one level out. The verifier tolerates an unreachable block that SAYS it is
        // unreachable; see XTIRVerifier §12.10.
        [self emitTerminator:XTIROpUnreachable operands:@[]];
        }
    }

- (void)lowerWhileStmt:(XTWhileNode*)node
    {
    NSString* prefix = [NSString stringWithFormat:@"bb_%lu",
                                                  (unsigned long)self.currentFunction.blocks.count];
    XTIRBlock* headerBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_header"]];
    XTIRBlock* bodyBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_body"]];
    XTIRBlock* exitBlock = [self addBlockWithName:[prefix stringByAppendingString:@"_exit"]];

    XTIRBlock* preheader = self.currentBlock;
    XTIRLocalSnapshot* preSnap = [self snapshotLocals];

    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:headerBlock] ]];

    // Pre-scan body AND CONDITION for assigned locals so we can place phis at
    // the header before lowering either (their values are patched into the
    // phi's body-operand at the end). The condition is scanned too because a
    // side-effecting condition (`while (n-- > 0)`) modifies a local that must be
    // loop-carried — without a phi, n kept its entry value and the loop never
    // terminated (bug 02). An `if` or a statement `n--` were fine; only a loop
    // condition dropped the update.
    NSMutableSet<NSString*>* assigned = [NSMutableSet set];
    [self collectAssignedLocalsIn:node.body into:assigned];
    if (node.condition)
        [self collectAssignedLocalsIn:node.condition into:assigned];

    // Insert placeholder phis at the header for each assigned local.
    // For each assigned local: phi(preheader → entry value, bodyExit → ?)
    // The bodyExit operand is a placeholder; we patch it later.
    NSMutableDictionary<NSString*, XTIRInsn*>* phiByName = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, XTIRValue*>* headerLocals = [NSMutableDictionary dictionary];
    for (NSString* name in preSnap)
        headerLocals[name] = preSnap[name];

    // SORTED, not the set's own order: an NSSet iterates in hash order, which
    // is stable within a build but is not a property of the program. The phi
    // ORDER at a loop header is visible in the IR text, so leaving it to the
    // hash makes the front end's output unpredictable from its input — and
    // unreproducible by any other implementation of the same lowering.
    for (NSString* name in [assigned.allObjects sortedArrayUsingSelector:@selector(compare:)])
        {
        XTIRValue* entryVal = preSnap[name];
        if (!entryVal)
            continue; // assigned-but-not-pre-defined → shouldn't happen for a var-decl-before-loop
        XTIRType* ty = entryVal.type;
        XTIRValueId vid = [self.currentFunction allocateValueId];
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:headerBlock insnIndex:0];
        XTIRValue* phiResult = [[XTIRValue alloc] initWithValueId:vid type:ty defSite:site];
        [self.currentFunction registerValue:phiResult];
        // Operands: (preheader, entryVal), (bodyBlock, PLACEHOLDER).
        // We use entryVal as the placeholder for the body edge — we
        // overwrite it after lowering the body.
        NSArray<XTIROperand*>* operands = @[
            [XTIROperand blockWithRef:preheader],
            [XTIROperand useWithValueId:entryVal.valueId],
            [XTIROperand blockWithRef:bodyBlock],
            [XTIROperand useWithValueId:entryVal.valueId],
        ];
        XTIRInsn* phi = [[XTIRInsn alloc] initWithOpcode:XTIROpPhi
                                                  result:phiResult
                                                operands:operands
                                                  dbgLoc:nil];
        [headerBlock.phiNodes addObject:phi];
        phiByName[name] = phi;
        headerLocals[name] = phiResult;
        }

    // Lower the header's condition.
    self.currentBlock = headerBlock;
    self.locals = headerLocals;
    XTIRBlock* condStart = self.currentBlock;
    XTIRValue* cond = [self lowerConditionExpr:node.condition];
    if (!cond)
        return;
    // A CONDITION is a full expression, so any +1 temporary it produced is
    // released here — before the branch, on the single path where it was
    // created. Nothing did this, so `if (list.get(0) != 0)` leaked the object
    // it tested: harmless while a +0 convention meant conditions rarely held a
    // +1, and a leak per test the moment every class-pointer return became +1.
    [self flushOwnedTempsFrom:condStart];
    // A short-circuit condition (`while (i < n && d > 0)`) lowers into extra
    // blocks, so the CondBranch is emitted in the LAST of them, not in the
    // header. That block is what actually branches to the exit — and the exit's
    // phis have to name it, or the verifier rejects the function with a §12.4
    // pred/phi mismatch. Found by the self-hosted preprocessor (M5), whose
    // parseCallArgs is exactly this shape: a `&&` loop condition with a break
    // inside the body.
    XTIRBlock* condExit = self.currentBlock;
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cond.valueId],
                            [XTIROperand blockWithRef:bodyBlock],
                            [XTIROperand blockWithRef:exitBlock] ]];

    // Lower the body. `break` targets the exit, `continue` the header
    // (a while loop has no separate increment to re-run). The frame's
    // "continues" bucket collects each continue edge so we can give the
    // header phis a matching operand per predecessor.
    NSMutableArray* continues = [NSMutableArray array];
    NSMutableArray* breaks = [NSMutableArray array];
    [self.loopStack addObject:@{@"header" : headerBlock,
                                @"arcDepth" : @(self.arcScopeStack.count),
                                @"exit" : exitBlock,
                                @"continues" : continues,
                                @"breaks" : breaks}];
    self.currentBlock = bodyBlock;
    self.locals = [headerLocals mutableCopy];
    [self lowerStatement:node.body];
    if (self.aborted)
        {
        [self.loopStack removeLastObject];
        return;
        }
    [self.loopStack removeLastObject];
    XTIRBlock* bodyExit = self.currentBlock;
    // The body falls through to the header only if it didn't already
    // self-terminate (e.g. end in a continue/break). A fall-through is
    // an additional header predecessor; a self-terminated bodyExit is
    // either a recorded continue edge or a break (→ exit), so it must
    // NOT also be counted as the fall-through back-edge.
    BOOL bodyFellThrough = (bodyExit.terminator == nil);
    if (bodyFellThrough)
        {
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:headerBlock] ]];
        }

    // Rebuild each header phi's operands: the preheader edge, the
    // fall-through back-edge (if any), then one operand per continue
    // edge. The operand count then matches the header's predecessor
    // count (verifier §12.4).
    for (NSString* name in phiByName)
        {
        XTIRInsn* phi = phiByName[name];
        XTIRValue* entryVal = preSnap[name];
        // Collect (predBlock, value) pairs, then order them by the
        // predecessor's index in fn.blocks — the verifier's §12.4
        // pred walk is in block order, and the phi's pairs must match.
        NSMutableArray<NSArray*>* pairs = [NSMutableArray array];
        [pairs addObject:@[ preheader, entryVal ]];
        if (bodyFellThrough)
            {
            [pairs addObject:@[ bodyExit, (self.locals[name] ?: entryVal) ]];
            }
        for (NSDictionary* rec in continues)
            {
            XTIRLocalSnapshot* cl = rec[@"locals"];
            [pairs addObject:@[ rec[@"block"], (cl[name] ?: entryVal) ]];
            }
        [pairs sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) {
          NSUInteger ia = [self.currentFunction.blocks indexOfObjectIdenticalTo:a[0]];
          NSUInteger ib = [self.currentFunction.blocks indexOfObjectIdenticalTo:b[0]];
          return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<XTIROperand*>* ops = [NSMutableArray array];
        for (NSArray* p in pairs)
            {
            [ops addObject:[XTIROperand blockWithRef:p[0]]];
            [ops addObject:[XTIROperand useWithValueId:((XTIRValue*)p[1]).valueId]];
            }
        [phi setValue:[ops copy] forKey:@"operands"];
        }

    // Post-loop code runs in the exit block. A while header always
    // tests the condition, so it reaches the exit on a false test;
    // merge that edge with any break edges.
    self.currentBlock = exitBlock;
    [self bindLoopExitLocalsInBlock:exitBlock
                        headerBlock:condExit
                  headerReachesExit:YES
                       headerLocals:headerLocals
                             breaks:breaks];
    }

// Pre-scan a sub-tree to collect names of locals assigned within
// it. Used by lowerWhileStmt to know which phis to place.
- (NSSet<NSString*>*)collectAssignedLocalsIn:(XTASTNode*)node
    {
    NSMutableSet<NSString*>* out = [NSMutableSet set];
    [self collectAssignedLocalsIn:node into:out];
    return out;
    }

- (void)collectAssignedLocalsIn:(XTASTNode*)node into:(NSMutableSet<NSString*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            [self collectAssignedLocalsIn:s into:out];
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectAssignedLocalsIn:n.thenBlock into:out];
        [self collectAssignedLocalsIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectAssignedLocalsIn:w.body into:out];
        break;
        }
    case XTASTNodeKindExprStatement:
        {
        XTExpressionStatementNode* e = (XTExpressionStatementNode*)node;
        [self collectAssignedLocalsIn:e.expression into:out];
        break;
        }
    case XTASTNodeKindAssignExpr:
        {
        XTAssignExprNode* a = (XTAssignExprNode*)node;
        if (a.lhs.nodeKind == XTASTNodeKindIdentifier)
            {
            [out addObject:((XTIdentifierNode*)a.lhs).identName];
            }
        // BOTH SIDES, not just the name on the left. `gOut[cnt++] = y` binds
        // nothing called gOut, so this case added nothing and stopped — and
        // `cnt` got no loop-carried phi, so the header kept the entry value,
        // the index was frozen at its initial 0, and the increment was dead
        // code. Every element landed in gOut[0] and the count came back 0.
        // The rhs holds the same shapes (`x = f(i++)`, `x = src[i++]`), and
        // there the frozen counter means the loop never terminates at all.
        // private:docs/bugs/241.
        [self collectAssignedLocalsIn:a.lhs into:out];
        [self collectAssignedLocalsIn:a.rhs into:out];
        break;
        }
    case XTASTNodeKindPostfixExpr:
        {
        // `i++` / `i--` rebind the local (lowerPostfixExpr:
        // updates self.locals). Without flagging it here no phi
        // is placed at the loop header, so the mutation is
        // invisible across the back-edge — a counted loop using
        // `i++` as its increment never terminates.
        XTPostfixExprNode* p = (XTPostfixExprNode*)node;
        if (p.operand.nodeKind == XTASTNodeKindIdentifier)
            {
            [out addObject:((XTIdentifierNode*)p.operand).identName];
            }
        break;
        }
    case XTASTNodeKindUnaryExpr:
        {
        // Prefix `++i` / `--i` rebind the local (lowerIncDecOn:
        // updates self.locals) — same phi requirement as the
        // postfix form above. Without flagging it, a loop using
        // `++i` as its step never sees the bump across the
        // back-edge. Other unary ops don't assign a local.
        XTUnaryExprNode* u = (XTUnaryExprNode*)node;
        if ((u.op == XTUnaryOpPreInc || u.op == XTUnaryOpPreDec) && u.operand.nodeKind == XTASTNodeKindIdentifier)
            {
            [out addObject:((XTIdentifierNode*)u.operand).identName];
            }
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        // A nested counted loop may assign an outer-scope local
        // (e.g. an accumulator). Recurse so the enclosing loop's
        // header gets a phi for it. The inner loop's own vars are
        // not live at the outer preheader, so they are filtered
        // out there (entryVal == nil → skipped).
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectAssignedLocalsIn:f.loopInit into:out];
        [self collectAssignedLocalsIn:f.body into:out];
        [self collectAssignedLocalsIn:f.increment into:out];
        break;
        }
    case XTASTNodeKindForIn:
        {
        // A nested for-in may assign an outer-scope local (e.g. an
        // accumulator updated across both loops). Recurse into its
        // body so the enclosing loop's header gets a phi for that
        // local — without this the outer loop never threads the
        // inner loop's accumulation, so the value resets each outer
        // iteration and post-loop code reads the pre-loop value. The
        // for-in's own loop variable / synthetic index are bound
        // inside its lowering (not as AST identifiers here), so they
        // don't leak into the outer loop's phi set.
        XTForInNode* f = (XTForInNode*)node;
        [self collectAssignedLocalsIn:f.body into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        [out addObject:vd.varName];
        break;
        }
    // Compound expressions can HOLD an assignment / postfix (`n-- > 0`,
    // `f(i++)`, `b ? x=1 : 0`). A loop CONDITION or a bare expression is
    // exactly such a tree, so descend into the operands or the local it
    // modifies goes unseen and gets no loop-carried phi (bug 02).
    case XTASTNodeKindBinaryExpr:
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        [self collectAssignedLocalsIn:b.left into:out];
        [self collectAssignedLocalsIn:b.right into:out];
        break;
        }
    case XTASTNodeKindCallExpr:
        {
        for (XTASTNode* a in ((XTCallExprNode*)node).arguments)
            [self collectAssignedLocalsIn:a into:out];
        break;
        }
    case XTASTNodeKindTernaryExpr:
        {
        XTTernaryExprNode* t = (XTTernaryExprNode*)node;
        [self collectAssignedLocalsIn:t.condition into:out];
        [self collectAssignedLocalsIn:t.thenExpr into:out];
        [self collectAssignedLocalsIn:t.elseExpr into:out];
        break;
        }
    // A compound STATEMENT inside a loop body assigns outer locals too — a
    // `switch` case, a `try`/`catch` arm, a `defer` body — so recurse into
    // each so the enclosing loop's header gets a phi. Without the switch arm
    // a `while (…) { switch (k) { case: s += … } }` never threaded the
    // accumulation across the back edge: the header carried no phi for `s`,
    // so it reset every iteration and the loop returned its pre-loop value
    // (bug 157, found as a self-host divergence — the ported lowering, which
    // recurses generically, already had this right).
    case XTASTNodeKindSwitch:
        {
        XTSwitchNode* sw = (XTSwitchNode*)node;
        [self collectAssignedLocalsIn:sw.subject into:out];
        for (XTSwitchCase* c in sw.cases)
            for (XTASTNode* st in c.body)
                [self collectAssignedLocalsIn:st into:out];
        break;
        }
    case XTASTNodeKindTry:
        {
        XTTryNode* t = (XTTryNode*)node;
        [self collectAssignedLocalsIn:t.tryBlock into:out];
        for (XTCatchClause* c in t.catchClauses)
            [self collectAssignedLocalsIn:c.block into:out];
        break;
        }
    case XTASTNodeKindDefer:
        {
        [self collectAssignedLocalsIn:((XTDeferNode*)node).body into:out];
        break;
        }
    // The remaining expression shapes a `++`/`--` can hide inside. This switch
    // enumerates what to descend into, and anything it forgets is silently not
    // descended into — which is the third time that has cost a real bug (157
    // was the switch arm, 241 the subscript index). The ported lowering
    // recurses over every child unconditionally and has been right each time;
    // this list is the wrong shape and should become a generic walk.
    case XTASTNodeKindSubscriptExpr:
        {
        XTSubscriptExprNode* sub = (XTSubscriptExprNode*)node;
        [self collectAssignedLocalsIn:sub.base into:out];
        [self collectAssignedLocalsIn:sub.index into:out];
        break;
        }
    case XTASTNodeKindMemberAccess:
        {
        [self collectAssignedLocalsIn:((XTMemberAccessNode*)node).base into:out];
        break;
        }
    case XTASTNodeKindCastExpr:
        {
        [self collectAssignedLocalsIn:((XTCastExprNode*)node).operand into:out];
        break;
        }
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* mc = (XTMethodCallExprNode*)node;
        [self collectAssignedLocalsIn:mc.receiver into:out];
        for (XTASTNode* a in mc.arguments)
            [self collectAssignedLocalsIn:a into:out];
        break;
        }
    case XTASTNodeKindReturn:
        {
        for (XTASTNode* v in ((XTReturnNode*)node).values)
            [self collectAssignedLocalsIn:v into:out];
        break;
        }
    default:
        break;
        }
    }

#pragma mark - Address-taken pre-scan + pinning

// Walk a function body collecting the set of identifier names that
// appear as the operand of a unary `&` (`XTUnaryOpAddrOf`) — these
// need to be pinned at function-entry so their address is stable
// for the duration of the call. Recursive walker covering the same
// AST kinds as collectAssignedLocalsIn: plus the expression slots
// that statement nodes own (if-cond, while-cond, return-value).
// Extract every C-style identifier (`[A-Za-z_][A-Za-z0-9_]*`) from an
// inline-asm line into `out`. Opcodes, labels and `$hex` tails come along
// too, but the caller only ever pins / rewrites those that turn out to be
// declared xtc locals (the VarDecl-type filter in the pin loop drops the
// rest), so over-collection here is harmless.
static void xtCollectAsmIdentifiers(NSString* line, NSMutableSet<NSString*>* out)
    {
    NSUInteger n = line.length, i = 0;
    while (i < n)
        {
        unichar c = [line characterAtIndex:i];
        if (c == ';')
            break; // rest of line is a comment — identifiers
                   // there (e.g. `; Clear numCols bytes`) must
                   // not pin a same-named local.
        if (isalpha((int)c) || c == '_')
            {
            NSUInteger start = i;
            while (i < n)
                {
                unichar d = [line characterAtIndex:i];
                if (isalnum((int)d) || d == '_')
                    i++;
                else
                    break;
                }
            [out addObject:[line substringWithRange:NSMakeRange(start, i - start)]];
            }
        else
            {
            i++;
            }
        }
    }

- (void)collectAddressTakenIn:(XTASTNode*)node
                         into:(NSMutableSet<NSString*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindAsmBlock:
        {
        // An inline-asm block that names an xtc local (`LDA $57 / STA
        // scrMode`) needs that local pinned to a stable ZP slot so the
        // asm's bare `STA scrMode` can resolve to it — otherwise the
        // identifier leaks as an undefined symbol → $0000. Collect
        // every identifier; the pin loop keeps only the real locals.
        for (NSString* line in ((XTAsmBlockNode*)node).lines)
            {
            xtCollectAsmIdentifiers(line, out);
            // Asm-named locals must keep a ZP address; record them
            // so the escapesViaPointer decision excludes them.
            xtCollectAsmIdentifiers(line, self.preScanAsmNamedNames);
            }
        break;
        }
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            {
            [self collectAddressTakenIn:s into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectAddressTakenIn:n.condition into:out];
        [self collectAddressTakenIn:n.thenBlock into:out];
        [self collectAddressTakenIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectAddressTakenIn:w.condition into:out];
        [self collectAddressTakenIn:w.body into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectAddressTakenIn:f.loopInit into:out];
        [self collectAddressTakenIn:f.condition into:out];
        [self collectAddressTakenIn:f.increment into:out];
        [self collectAddressTakenIn:f.body into:out];
        break;
        }
    case XTASTNodeKindReturn:
        {
        XTReturnNode* r = (XTReturnNode*)node;
        for (XTASTNode* v in r.values)
            {
            [self collectAddressTakenIn:v into:out];
            }
        break;
        }
    case XTASTNodeKindExprStatement:
        {
        XTExpressionStatementNode* e = (XTExpressionStatementNode*)node;
        [self collectAddressTakenIn:e.expression into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        [self collectAddressTakenIn:vd.initialiser into:out];
        break;
        }
    case XTASTNodeKindUnaryExpr:
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)node;
        if (u.op == XTUnaryOpAddrOf)
            {
            // `&obj.method` — a BOUND METHOD reference — does not take the
            // address of `obj` at all: the receiver is read BY VALUE into
            // the fat pointer's recv word. Pinning it here was actively
            // harmful — an address-taken local is excluded from ARC's
            // strong-local set, so `act_t^ h = &c.g;` silently suppressed
            // c's scope-exit release and LEAKED the receiver.
            if (u.operand.nodeKind == XTASTNodeKindMemberAccess && ((XTMemberAccessNode*)u.operand).resolvedBoundMethod != nil)
                {
                break;
                }
            // Walk through member-access chains (dot form only) to
            // the underlying identifier. `&a.b.c` pins `a`; `&p->x`
            // pins nothing here because `p` is a pointer whose
            // value we'll use directly.
            XTASTNode* cur = u.operand;
            while (cur && cur.nodeKind == XTASTNodeKindMemberAccess)
                {
                XTMemberAccessNode* m = (XTMemberAccessNode*)cur;
                if (m.isArrow)
                    {
                    cur = nil;
                    break;
                    }
                cur = m.base;
                }
            if (cur && cur.nodeKind == XTASTNodeKindIdentifier)
                {
                NSString* nm = ((XTIdentifierNode*)cur).identName;
                [out addObject:nm];
                // The pointer to this local escapes; record it so the
                // pre-scan flags it escapesViaPointer (keeping it out of
                // the call-clobbered shared ZP pinned-local pool).
                [self.preScanAmpTakenNames addObject:nm];
                }
            }
        [self collectAddressTakenIn:u.operand into:out];
        break;
        }
    case XTASTNodeKindBinaryExpr:
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        [self collectAddressTakenIn:b.left into:out];
        [self collectAddressTakenIn:b.right into:out];
        break;
        }
    case XTASTNodeKindAssignExpr:
        {
        XTAssignExprNode* a = (XTAssignExprNode*)node;
        // Record a plain `name = …`. A PARAMETER that is assigned needs
        // to become a strong slot (private:docs/bugs/064) and that decision has
        // to be made before the body is lowered — this walk is already
        // the one pre-pass over the body, so it collects it here rather
        // than growing a second traversal to drift against.
        if (a.lhs && a.lhs.nodeKind == XTASTNodeKindIdentifier && a.lhs.resolvedType && [self astTypeIsClassPointer:a.lhs.resolvedType])
            {
            NSString* n = ((XTIdentifierNode*)a.lhs).identName;
            if (n)
                [self.preScanAssignedNames addObject:n];
            }
        [self collectAddressTakenIn:a.lhs into:out];
        [self collectAddressTakenIn:a.rhs into:out];
        break;
        }
    case XTASTNodeKindCallExpr:
        {
        XTCallExprNode* c = (XTCallExprNode*)node;
        // A va_start / va_arg_<T> intrinsic carries its cursor as the
        // first argument. Record the cursor identifier so the pre-scan
        // pins it to a frame slot — memory-backing the loop-carried
        // offset (see preScanVarargCursorNames / task #120).
        NSString* cm = c.resolvedMangledName;
        if (cm && [cm hasPrefix:@"__intrinsic_va_"] && c.arguments.count >= 1 && c.arguments[0].nodeKind == XTASTNodeKindIdentifier)
            {
            [self.preScanVarargCursorNames addObject:
                                               ((XTIdentifierNode*)c.arguments[0]).identName];
            }
        for (XTASTNode* a in c.arguments)
            {
            [self collectAddressTakenIn:a into:out];
            }
        break;
        }
    case XTASTNodeKindMethodCallExpr:
        {
        XTMethodCallExprNode* m = (XTMethodCallExprNode*)node;
        [self collectAddressTakenIn:m.receiver into:out];
        for (XTASTNode* a in m.arguments)
            {
            [self collectAddressTakenIn:a into:out];
            }
        break;
        }
    case XTASTNodeKindSubscriptExpr:
        {
        XTSubscriptExprNode* s = (XTSubscriptExprNode*)node;
        [self collectAddressTakenIn:s.base into:out];
        [self collectAddressTakenIn:s.index into:out];
        break;
        }
    case XTASTNodeKindMemberAccess:
        {
        XTMemberAccessNode* m = (XTMemberAccessNode*)node;
        [self collectAddressTakenIn:m.base into:out];
        break;
        }
    case XTASTNodeKindCastExpr:
        {
        XTCastExprNode* c = (XTCastExprNode*)node;
        [self collectAddressTakenIn:c.operand into:out];
        break;
        }
    case XTASTNodeKindTernaryExpr:
        {
        // `human ? f(&res) : g(&res)` — the address-of hides in a branch.
        // Without descending here the local was never pinned and `&res`
        // aborted with "not pinned" (bug 19). The condition can take an
        // address too, so walk all three.
        XTTernaryExprNode* t = (XTTernaryExprNode*)node;
        [self collectAddressTakenIn:t.condition into:out];
        [self collectAddressTakenIn:t.thenExpr into:out];
        [self collectAddressTakenIn:t.elseExpr into:out];
        break;
        }
    default:
        break;
        }
    }

// Every local VARIABLE-DECL name in a subtree — used to pin them all in a
// function that contains a `goto`.
- (void)collectAllLocalNamesIn:(XTASTNode*)node into:(NSMutableSet<NSString*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindVariableDecl:
        if (((XTVariableDeclNode*)node).varName)
            [out addObject:((XTVariableDeclNode*)node).varName];
        break;
    case XTASTNodeKindBlock:
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            [self collectAllLocalNamesIn:st into:out];
        break;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectAllLocalNamesIn:n.thenBlock into:out];
        [self collectAllLocalNamesIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        [self collectAllLocalNamesIn:((XTWhileNode*)node).body into:out];
        break;
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectAllLocalNamesIn:f.loopInit into:out];
        [self collectAllLocalNamesIn:f.body into:out];
        break;
        }
    case XTASTNodeKindForIn:
        [self collectAllLocalNamesIn:((XTForInNode*)node).body into:out];
        break;
    case XTASTNodeKindSwitch:
        for (XTSwitchCase* c in ((XTSwitchNode*)node).cases)
            for (XTASTNode* st in c.body)
                [self collectAllLocalNamesIn:st into:out];
        break;
    default:
        break;
        }
    }

// Collect the names of function-local `static` declarations (a static
// whose storage is a persistent module global, not a frame slot). The
// pre-scan must NOT pin these: an address-taken static ARRAY (`static
// u8 buf[64]` used as `&buf[0]`) would otherwise get BOTH a frame slot
// (from the pin loop) and a backing global (from lowerStaticLocalDecl),
// and address resolution prefers the frame slot — so the array is not
// static at all: its contents are lost between calls and a returned
// pointer dangles (bug 174). A static SCALAR escaped this because it is
// never address-taken here, so it was never pinned. Restricting the
// exclusion to statics keeps every ordinary address-taken local pinned.
- (void)collectStaticLocalNamesIn:(XTASTNode*)node
                             into:(NSMutableSet<NSString*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if (vd.varName && vd.isStatic && !vd.isGlobal)
            [out addObject:vd.varName];
        break;
        }
    case XTASTNodeKindBlock:
        for (XTASTNode* st in ((XTBlockNode*)node).statements)
            [self collectStaticLocalNamesIn:st into:out];
        break;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectStaticLocalNamesIn:n.thenBlock into:out];
        [self collectStaticLocalNamesIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        [self collectStaticLocalNamesIn:((XTWhileNode*)node).body into:out];
        break;
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectStaticLocalNamesIn:f.loopInit into:out];
        [self collectStaticLocalNamesIn:f.body into:out];
        break;
        }
    case XTASTNodeKindForIn:
        [self collectStaticLocalNamesIn:((XTForInNode*)node).body into:out];
        break;
    case XTASTNodeKindSwitch:
        for (XTSwitchCase* c in ((XTSwitchNode*)node).cases)
            for (XTASTNode* st in c.body)
                [self collectStaticLocalNamesIn:st into:out];
        break;
    default:
        break;
        }
    }

// Pre-scan the body, then allocate pinned slots for every address-
// taken local. Walks the names in alphabetical order so re-runs
// produce identical IR (the offsets are stable across re-emits).
- (void)preScanAddressTakenLocalsIn:(XTASTNode*)body
                                 fn:(XTIRFunction*)fn
    {
    NSMutableSet<NSString*>* addressed = [NSMutableSet set];
    self.preScanAmpTakenNames = [NSMutableSet set];
    self.preScanAsmNamedNames = [NSMutableSet set];
    self.preScanVarargCursorNames = [NSMutableSet set];
    self.preScanAssignedNames = [NSMutableSet set];
    [self collectAddressTakenIn:body into:addressed];
    // A function with a `goto` pins EVERY local, so a jump is a plain branch
    // with no SSA reconstruction across the (possibly irreducible) edge — every
    // read/write already goes through the slot. Also record each label's scope
    // depth for the goto teardown. (goto is a C-porting aid; see lowerGotoStmt:.)
    self.labelBlocks = [NSMutableDictionary dictionary];
    self.labelDepths = [NSMutableDictionary dictionary];
    if ([self astContainsGoto:body])
        {
        NSString* why = [self gotoUnsupportedReasonIn:body];
        if (why)
            {
            [self softFailLoweringAt:nil
                         withMessage:[NSString stringWithFormat:
                                                   @"goto in a function with %@ is not supported (goto is a C-porting aid)", why]];
            }
        else
            {
            [self collectAllLocalNamesIn:body into:addressed];
            [self collectLabelDepthsIn:body atDepth:1];
            }
        }
    // Locals whose address is explicitly `&`-taken (so their pointer can
    // escape into a call and be dereferenced across it) must NOT live in
    // the shared, per-function-reset ZP pinned-local pool — a callee's
    // pinned locals alias the same ZP bytes and clobber them. Flag them
    // escapesViaPointer below so the backend gives them stable storage.
    // Asm-named locals are excluded: they need a ZP address for `STA name`
    // / `(name),Y` addressing (and a leaf asm helper isn't clobbered).
    NSMutableSet<NSString*>* ptrEscapeNames = [self.preScanAmpTakenNames mutableCopy];
    [ptrEscapeNames minusSet:self.preScanAsmNamedNames];
    // A va_* cursor is loop-carried state read between the calls printf
    // makes per format directive; like an `&`-taken local it must have
    // stable storage a callee can't reuse, so flag it escapesViaPointer
    // (out of the shared per-function-reset ZP pinned-local pool).
    [ptrEscapeNames unionSet:self.preScanVarargCursorNames];

    // Value-typed struct locals must be pinned regardless of whether
    // their address is ever taken: an aggregate can't live in an SSA
    // scalar value, so every access (`p.x`, `p.x = …`, `&p.x`) goes
    // through the slot's address. Collect them and union into the set
    // the pre-scan pins (a name already `&`-taken de-dups via the set,
    // so we never double-pin).
    NSMutableDictionary<NSString*, XTType*>* structLocals =
        [NSMutableDictionary dictionary];
    [self collectStructLocalDeclsIn:body into:structLocals];
    [addressed addObjectsFromArray:structLocals.allKeys];
    // Split out the array-typed entries — lowerIdentifier needs to
    // tell `u16 buf[N]` from `Point p;` so the array form decays to
    // a pointer instead of loading the aggregate value when used by
    // bare name.
    for (NSString* name in structLocals)
        {
        XTType* ty = structLocals[name];
        if (ty.kind == XTTypeKindArray && [ty isKindOfClass:[XTArrayType class]])
            {
            [self.arrayLocalNames addObject:name];
            self.arrayLocalElementType[name] = ((XTArrayType*)ty).elementType;
            }
        }

    // Sized-scalar locals initialised from a byte-list with non-constant
    // entries (`float r = {$00, $FF, m0, …}`) must also be pinned: the
    // value is assembled by per-byte stores into the slot, which needs an
    // address. All-constant byte-lists assemble into a single Const and
    // stay unpinned (no IR change), so only the non-constant ones land
    // here.
    NSMutableDictionary<NSString*, XTType*>* scalarByteListLocals =
        [NSMutableDictionary dictionary];
    [self collectScalarByteListInitLocalsIn:body into:scalarByteListLocals];
    [addressed addObjectsFromArray:scalarByteListLocals.allKeys];

    // Stack-allocated (value) class instances — `Animal a;` with no
    // `new`. Like a value struct, the instance memory IS the frame
    // slot, so the local must be pinned; but its slot is sized by the
    // class's instanceLayout (vtable ptr + ivars), not a pointer width.
    // The pin loop below special-cases the IR type for these names and
    // records each in self.valueClassLocals.
    NSMutableDictionary<NSString*, XTType*>* classValueLocals =
        [NSMutableDictionary dictionary];
    [self collectClassValueLocalDeclsIn:body into:classValueLocals];
    [addressed addObjectsFromArray:classValueLocals.allKeys];

    // va_* cursors are var-decl locals (`u8 ap;`); union them in so the
    // pin loop allocates a frame slot and collectVarDeclTypesIn: below
    // recovers their declared type (task #120).
    [addressed unionSet:self.preScanVarargCursorNames];

    // A function-local `static` is backed by a module global, not a frame
    // slot (lowerStaticLocalDecl). Drop such names from every pin-driving set
    // so an address-taken static array is not ALSO pinned — the frame pin
    // would shadow the global and lose the static storage (bug 174). A vararg
    // cursor is never static, so the union above is unaffected.
    NSMutableSet<NSString*>* staticLocalNames = [NSMutableSet set];
    [self collectStaticLocalNamesIn:body into:staticLocalNames];
    if (staticLocalNames.count)
        {
        [addressed minusSet:staticLocalNames];
        for (NSString* sn in staticLocalNames)
            {
            [self.arrayLocalNames removeObject:sn];
            [self.arrayLocalElementType removeObjectForKey:sn];
            [structLocals removeObjectForKey:sn];
            [scalarByteListLocals removeObjectForKey:sn];
            [classValueLocals removeObjectForKey:sn];
            }
        }

    if (addressed.count == 0)
        return;

    // Find each name's declared AST type by walking the body. The
    // names are var-decls (we don't pin parameters in this task);
    // the walk records the first declared type seen for each name.
    NSMutableDictionary<NSString*, XTType*>* typesByName =
        [NSMutableDictionary dictionary];
    [self collectVarDeclTypesIn:body forNames:addressed into:typesByName];
    // The struct-local walk already carries each one's declared type;
    // merge it in (collectVarDeclTypesIn: would find them too, but this
    // keeps the struct types authoritative).
    [typesByName addEntriesFromDictionary:structLocals];
    [typesByName addEntriesFromDictionary:scalarByteListLocals];
    [typesByName addEntriesFromDictionary:classValueLocals];

    // Detect names re-declared at more than one distinct type (only plain
    // scalars — aggregates carry one authoritative type via the maps above).
    // Such a name gets a slot per distinct type below; a name declared at a
    // single type is absent here and keeps its original single-slot layout.
    NSMutableDictionary<NSString*, NSMutableArray<XTType*>*>* declTypeLists =
        [NSMutableDictionary dictionary];
    [self collectVarDeclTypeListsIn:body forNames:addressed into:declTypeLists];
    NSMutableDictionary<NSString*, NSArray<XTType*>*>* multiTypeNames =
        [NSMutableDictionary dictionary];
    for (NSString* nm in declTypeLists)
        {
        // An AGGREGATE declaration no longer opts the name out. It used to:
        // `structLocals` (which holds arrays as well as structs) carried "one
        // authoritative type", so a name declared BOTH as an array and as a
        // scalar in sibling blocks collapsed onto ONE slot typed as the array —
        // and, because arrayLocalNames is keyed by NAME, the scalar's every
        // bare-name read then decayed to the array's ADDRESS. `tbl[m]` lowered
        // as `tbl[&m]`: no diagnostic, SIGBUS at run time. A name declared at
        // one type only still has a single distinct type and is unaffected.
        //
        // Value-class instances and byte-list scalars keep the opt-out: their
        // slots are sized bespokely below (an instanceLayout Agg, a widened
        // byte-list scalar), which the per-type loop does not reproduce.
        if (scalarByteListLocals[nm] || classValueLocals[nm])
            continue;
        // Distinctness is by type SPELLING, not object identity. The scalar
        // types are singletons, so identity worked while only scalars got here;
        // an ARRAY type is built per declaration, so two identical `u8 m[32]`
        // are two objects and would have looked like two types — giving one
        // local two slots. The slot map below is keyed by displayName anyway,
        // so the two would then collapse onto one entry and leak the other.
        NSMutableArray<XTType*>* distinct = [NSMutableArray array];
        NSMutableSet<NSString*>* seenSpellings = [NSMutableSet set];
        for (XTType* t in declTypeLists[nm])
            {
            NSString* dn = t.displayName;
            if (!dn || [seenSpellings containsObject:dn])
                continue;
            [seenSpellings addObject:dn];
            [distinct addObject:t];
            }
        if (distinct.count > 1)
            multiTypeNames[nm] = distinct;
        }

    NSArray<NSString*>* sortedNames =
        [addressed.allObjects sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<XTIRPinnedLocal*>* pinned =
        [fn.frameInfo.pinnedLocals mutableCopy] ?: [NSMutableArray array];
    uint32_t offset = fn.frameInfo.pinnedLocalSize;

    for (NSString* name in sortedNames)
        {
        XTType* astTy = typesByName[name];
        if (!astTy)
            {
            // Not a var-decl. If it's a PARAM referenced from inline asm
            // (or via &), register it in pinnedLocals using the param's
            // own value-id so lowerAsmBlock rewrites `name` → its
            // {{XTLOCAL}} token (the backend then ZP-pins that value so
            // ZP-style asm addressing — `name`, `name+1`, `(name),Y` —
            // works). Without this, an asm reference to a pointer/scalar
            // param leaks as a bare undefined symbol → $0000. The
            // value-typed-struct-param case is already handled at fn entry.
            XTIRValue* paramVal = self.locals[name];
            // A scalar/pointer parameter whose address is explicitly `&`-taken
            // must get its OWN frame slot, initialised from the incoming param
            // value at entry — exactly as `T j = j0; &j` does. Aliasing AddrOf
            // to the param value itself is wrong once the function is inlined:
            // the callee's `AddrOf param; Store` mutates the caller's argument
            // SSA value, corrupting a shared argument such as a constant that
            // also feeds later calls (bug 202: `viaParam(10)` inlined mutated the
            // `10` that the next `viaLocal(10)` then read as 15). Asm-named params
            // keep the alias (they need the param's ZP address for `STA name`);
            // aggregates already ride their prologue param slot (handled at fn
            // entry). So this covers only `&`-taken, non-asm, non-Agg params.
            if (paramVal && !self.pinnedLocals[name] && [ptrEscapeNames containsObject:name] && ![name isEqualToString:@"self"] && paramVal.type.kind != XTIRTypeKindAgg)
                {
                XTIRValueId vid = [fn allocateValueId];
                XTIRPinnedLocal* pl = [[XTIRPinnedLocal alloc]
                    initWithName:name
                            type:paramVal.type
                      byteOffset:offset
                         valueId:vid];
                pl.escapesViaPointer = YES;
                [pinned addObject:pl];
                XTIRValue* slotV = [[XTIRValue alloc] initWithValueId:vid
                                                                 type:paramVal.type
                                                              defSite:[XTIRDefSite parameterDef]];
                [fn registerValue:slotV];
                self.pinnedLocals[name] = pl;
                self.pinnedParamInit[name] = paramVal; // prologue copies it in
                offset += paramVal.type.byteWidth;
                continue;
                }
            if (paramVal && !self.pinnedLocals[name])
                {
                self.pinnedLocals[name] = [[XTIRPinnedLocal alloc]
                    initWithName:name
                            type:paramVal.type
                      byteOffset:0
                         valueId:paramVal.valueId];
                }
            continue;
            }
        // Re-declared at multiple distinct types (e.g. `{ u8 c … } { u32 c … }`
        // where both blocks name `c` in inline asm): one slot per distinct
        // type, each registered so lowerVarDecl can rebind self.pinnedLocals
        // [name] to the type that matches the declaration it's lowering.
        NSArray<XTType*>* distinctTypes = multiTypeNames[name];
        if (distinctTypes)
            {
            NSMutableDictionary<NSString*, XTIRPinnedLocal*>* byType =
                [NSMutableDictionary dictionary];
            // Same escape rule the single-slot path applies: an ARRAY local
            // decays to a pointer at every bare-name use and the callee writes
            // through it, so its storage may not live in the shared per-function
            // ZP pool a callee reuses. Keyed by name, as it is there — a name
            // with an array declaration escapes for all of its slots.
            BOOL isEscape = [ptrEscapeNames containsObject:name] || ([self.arrayLocalNames containsObject:name] && ![self.preScanAsmNamedNames containsObject:name]);
            for (XTType* dt in distinctTypes)
                {
                XTIRType* irTy = [self irTypeForASTTypeQuiet:dt];
                if (!irTy)
                    continue;
                XTIRValueId vid = [fn allocateValueId];
                XTIRPinnedLocal* pl = [[XTIRPinnedLocal alloc]
                    initWithName:name
                            type:irTy
                      byteOffset:offset
                         valueId:vid];
                if (isEscape)
                    pl.escapesViaPointer = YES;
                [pinned addObject:pl];
                XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                             type:irTy
                                                          defSite:[XTIRDefSite parameterDef]];
                [fn registerValue:v];
                byType[dt.displayName] = pl;
                offset += irTy.byteWidth;
                }
            if (byType.count)
                {
                self.pinnedLocalsByType[name] = byType;
                // Seed a default binding so any reference before the first
                // in-scope declaration still resolves (lowerVarDecl rebinds).
                self.pinnedLocals[name] = byType[distinctTypes.firstObject.displayName];
                }
            continue;
            }
        // A value-class local's slot is the instance itself — size it
        // by the class's Agg(instanceLayout), NOT by selfPtrType (which
        // is what irTypeForASTTypeQuiet: returns for a bare class type).
        // Record it so identifier / method-call lowering treats `name`
        // as a self-pointer to the slot.
        XTIRClassInfo* vci = nil;
        if (astTy.kind == XTTypeKindClass && ![astTy isKindOfClass:[XTPointerType class]])
            {
            vci = self.classesByName[astTy.displayName];
            }
        XTIRType* irTy = vci ? [XTIRType aggWithLayout:vci.instanceLayout]
                             : [self irTypeForASTTypeQuiet:astTy];
        if (!irTy)
            continue;
        // A WEAK local's slot carries two hidden link words BEFORE the payload,
        // so the runtime finds them at the same negative offset it uses for a
        // weak ivar. They must live in the pin's TYPE, not merely in its
        // byteOffset: the backends assign a pinned local's stack slot per VALUE,
        // sized from pl.type, and never read pl.byteOffset — so reserving space
        // by advancing the offset would let the links land on a neighbour.
        //
        // pl.type therefore becomes Agg[prev, next, payload], and the PAYLOAD
        // address is FieldAddr(AddrOf(pl), 2) — see payloadAddrForPinnedLocal:.
        if ([self astTypeIsWeakSlot:astTy])
            {
            irTy = [self weakSlotAggFor:irTy];
            }
        XTIRValueId vid = [fn allocateValueId];
        XTIRPinnedLocal* pl = [[XTIRPinnedLocal alloc]
            initWithName:name
                    type:irTy
              byteOffset:offset
                 valueId:vid];
        // A stack-allocated class instance is only ever reached through
        // its self-pointer, which is passed into method calls; flag it so
        // backends keep it out of any shared scratch pool a callee could
        // clobber (see XTIRPinnedLocal.escapesViaPointer). The same hazard
        // applies to any local whose address is explicitly `&`-taken and
        // dereferenced across a call.
        //
        // Array-typed pinned locals (`u16 buf[N]`) decay to a pointer at
        // every bare-name use (`Sort.qsort(buf, …)`); the callee then
        // mutates the slot via that pointer. A ZP allocation routes
        // through the caller-save save/restore around the call, which
        // would undo every mutation. Flag arrays as escaping so they
        // land in the per-function static spill (a stable address the
        // callee can read/write across) — UNLESS the array's name is
        // referenced by an inline-asm block. Inline-asm name binding
        // resolves through ZP slots / static spill labels; a non-leaf
        // function's escaping pin would go to the software-stack frame
        // instead, where bare-name binding has no static address to
        // resolve to (asm_zp_pressure tests exactly this case).
        if (vci || [ptrEscapeNames containsObject:name])
            pl.escapesViaPointer = YES;
        if ([self.arrayLocalNames containsObject:name] && ![self.preScanAsmNamedNames containsObject:name])
            {
            pl.escapesViaPointer = YES;
            }
        [pinned addObject:pl];
        // Register a value whose value-id matches the pinned-local
        // so AddrOf operands can reference it via Use(valueId).
        // The value's TYPE is the POINTEE type (irTy) — the backend
        // uses this to size the storage slot. The Ptr-typed value
        // that AddrOf produces is a SEPARATE SSA value, allocated
        // at the AddrOf call site.
        XTIRDefSite* site = [XTIRDefSite parameterDef];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                     type:irTy
                                                  defSite:site];
        [fn registerValue:v];
        self.pinnedLocals[name] = pl;
        if (astTy)
            self.pinnedLocalASTType[name] = astTy;
        if (vci)
            self.valueClassLocals[name] = vci;
        // Accumulate the frame size in IR-type widths — the same widths
        // the verifier's §12.11 frame check sums (`pl.type.byteWidth`),
        // so the accounting is self-consistent by construction. This is a
        // no-op for every type whose source width equals its IR width
        // (all integers, pointers, `double`, structs/arrays), and matters
        // only for xtc `float`: a 5-byte source that maps to the 4-byte
        // IR F32. Each backend re-derives the real slot size from its own
        // byteWidthForType (xt6502 sizes F32 as 5, arm64 uses 8-byte value
        // slots), so this width drives only the §12.11/printer bookkeeping,
        // never the emitted layout.
        offset += irTy.byteWidth;
        }
    fn.frameInfo.pinnedLocals = [pinned copy];
    fn.frameInfo.pinnedLocalSize = offset;
    }

// Helper for preScanAddressTakenLocalsIn: walk the body recording
// the declared type of every var-decl whose name appears in
// `targetNames`. Same shape as collectAddressTakenIn:into: but
// emitting type info.
- (void)collectVarDeclTypesIn:(XTASTNode*)node
                     forNames:(NSSet<NSString*>*)names
                         into:(NSMutableDictionary<NSString*, XTType*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            {
            [self collectVarDeclTypesIn:s forNames:names into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectVarDeclTypesIn:n.thenBlock forNames:names into:out];
        [self collectVarDeclTypesIn:n.elseBlock forNames:names into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectVarDeclTypesIn:w.body forNames:names into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectVarDeclTypesIn:f.loopInit forNames:names into:out];
        [self collectVarDeclTypesIn:f.body forNames:names into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if ([names containsObject:vd.varName] && vd.declaredType)
            {
            out[vd.varName] = vd.declaredType;
            }
        break;
        }
    default:
        break;
        }
    }

// Same traversal as collectVarDeclTypesIn:forNames:into:, but records EVERY
// declaration's type per name (appending to a per-name array) rather than
// keeping only the last. The pre-scan uses this to spot a name re-declared
// at more than one distinct type — those need a slot per type (see
// pinnedLocalsByType) instead of a single name-keyed slot.
- (void)collectVarDeclTypeListsIn:(XTASTNode*)node
                         forNames:(NSSet<NSString*>*)names
                             into:(NSMutableDictionary<NSString*, NSMutableArray<XTType*>*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            {
            [self collectVarDeclTypeListsIn:s forNames:names into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectVarDeclTypeListsIn:n.thenBlock forNames:names into:out];
        [self collectVarDeclTypeListsIn:n.elseBlock forNames:names into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectVarDeclTypeListsIn:w.body forNames:names into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectVarDeclTypeListsIn:f.loopInit forNames:names into:out];
        [self collectVarDeclTypeListsIn:f.body forNames:names into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if ([names containsObject:vd.varName] && vd.declaredType)
            {
            NSMutableArray<XTType*>* list = out[vd.varName];
            if (!list)
                {
                list = [NSMutableArray array];
                out[vd.varName] = list;
                }
            [list addObject:vd.declaredType];
            }
        break;
        }
    default:
        break;
        }
    }

// Helper for preScanAddressTakenLocalsIn: walk the body recording every
// value-typed struct local var-decl (name → declared type). A value
// aggregate needs a real frame slot even when its address is never taken
// because member access lowers through the slot address. A
// pointer-to-struct (`Point@`) reports kind == XTTypeKindPointer, stays
// an SSA pointer value, and is deliberately NOT collected here. Same
// traversal shape as collectVarDeclTypesIn:forNames:into:.
- (void)collectStructLocalDeclsIn:(XTASTNode*)node
                             into:(NSMutableDictionary<NSString*, XTType*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            {
            [self collectStructLocalDeclsIn:s into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectStructLocalDeclsIn:n.thenBlock into:out];
        [self collectStructLocalDeclsIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectStructLocalDeclsIn:w.body into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectStructLocalDeclsIn:f.loopInit into:out];
        [self collectStructLocalDeclsIn:f.body into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        XTType* ty = vd.declaredType;
        // Value-typed aggregates — structs AND arrays — can't live
        // in an SSA scalar, so pin them: member access / subscript
        // lower through the slot's address. Pointer-to-struct
        // (`Point@`) and pointer types stay SSA values.
        BOOL isStruct = (ty.kind == XTTypeKindStruct && [ty isKindOfClass:[XTStructType class]]);
        BOOL isArray = (ty.kind == XTTypeKindArray && [ty isKindOfClass:[XTArrayType class]]);
        // A WEAK local must be pinned too, even though a pointer would
        // otherwise live happily in an SSA value. The weak side table
        // zeroes the slot's MEMORY when the target dies — an SSA copy would
        // never see that, so the guard would still read the stale pointer.
        // Pinning forces every read to Load from the slot, which is what
        // makes auto-zeroing observable. (A `^` is a struct and is already
        // pinned by the isStruct arm.)
        BOOL isWeakPtr = [self astTypeIsWeakClassPointer:ty];
        if (vd.varName && ty && (isStruct || isArray || isWeakPtr))
            {
            out[vd.varName] = ty;
            }
        break;
        }
    default:
        break;
        }
    }

// Helper for preScanAddressTakenLocalsIn: record every stack-allocated
// (value) class instance var-decl (`Animal a;` with no `new`). Only the
// bare, initialiser-free form is collected — the slot is sized by the
// class's instanceLayout and zero-or-init-filled at the decl. A
// class-POINTER local (`Animal@ a = new …`) reports kind ==
// XTTypeKindPointer, stays an SSA pointer value, and is NOT collected.
// A value-class decl with an initialiser (e.g. `Point b = a.clone();`)
// is left on its existing path (class return-by-value is a separate
// task) so this change can't regress it. Same traversal shape as
// collectStructLocalDeclsIn:into:.
- (void)collectClassValueLocalDeclsIn:(XTASTNode*)node
                                 into:(NSMutableDictionary<NSString*, XTType*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            {
            [self collectClassValueLocalDeclsIn:s into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectClassValueLocalDeclsIn:n.thenBlock into:out];
        [self collectClassValueLocalDeclsIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectClassValueLocalDeclsIn:w.body into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectClassValueLocalDeclsIn:f.loopInit into:out];
        [self collectClassValueLocalDeclsIn:f.body into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        XTType* ty = vd.declaredType;
        // Collect value-class locals that need a pinned slot:
        //  * no initialiser (the original `<C> b;` shape), or
        //  * initialiser is `recv.clone()` — the lowerVarDecl
        //    clone-intercept then field-copies straight into the slot.
        // Other value-class-with-init shapes (`<C> p = makePoint()`,
        // `<C> b = a.translate()`, user-clone init) stay on the
        // existing non-pinned aggregate-flow path that already works.
        if (vd.varName && ty && ty.kind == XTTypeKindClass && ![ty isKindOfClass:[XTPointerType class]] && self.classesByName[ty.displayName])
            {
            BOOL needsPin = !vd.initialiser;
            if (!needsPin && vd.initialiser && vd.initialiser.nodeKind == XTASTNodeKindMethodCallExpr)
                {
                XTMethodCallExprNode* call =
                    (XTMethodCallExprNode*)vd.initialiser;
                if ([call.methodName isEqualToString:@"clone"] && call.arguments.count == 0)
                    {
                    // Only pin when the receiver's class has NO user
                    // `clone` — that's exactly when the lowerVarDecl
                    // clone-intercept fires (field-by-field copy). A
                    // user-defined clone stays on the existing
                    // non-pinned aggregate-flow path (which works).
                    XTType* rcvT = call.receiver.resolvedType;
                    XTType* rcvPointee = rcvT;
                    if (rcvT && [rcvT isKindOfClass:[XTPointerType class]])
                        rcvPointee = ((XTPointerType*)rcvT).pointeeType;
                    if (rcvPointee && rcvPointee.kind == XTTypeKindClass)
                        {
                        // hasUserClone must use the AST (classDeclsByName),
                        // not module.symbolForName — the function-body
                        // pre-scan runs BEFORE every class's method
                        // symbols are registered, so the module lookup
                        // would consistently miss and pin every
                        // `<C> b = a.clone()` even when `clone` is
                        // user-defined. classDeclsByName is fully
                        // populated by the time any body is walked.
                        BOOL hasUserClone = NO;
                        for (XTClassDeclNode* c = self.classDeclsByName[rcvPointee.displayName];
                             c != nil; c = c.parentClass)
                            {
                            for (XTMethodDeclNode* m in c.methods)
                                {
                                if ([m.methodName isEqualToString:@"clone"] && m.parameters.count == 0)
                                    {
                                    hasUserClone = YES;
                                    break;
                                    }
                                }
                            if (hasUserClone)
                                break;
                            }
                        needsPin = !hasUserClone;
                        }
                    }
                }
            if (needsPin)
                out[vd.varName] = ty;
            }
        break;
        }
    default:
        break;
        }
    }

// Helper for preScanAddressTakenLocalsIn: record every sized-scalar
// var-decl (name → declared type) whose initialiser is a byte-list
// (`{ … }`) with at least one non-constant entry. Such a local can't be
// built from a single Const, so it needs an addressable frame slot that
// the per-byte stores write into. An all-constant byte-list folds to a
// Const and is deliberately NOT collected here (it stays an SSA value,
// preserving its IR). Same traversal shape as collectStructLocalDeclsIn:.
- (void)collectScalarByteListInitLocalsIn:(XTASTNode*)node
                                     into:(NSMutableDictionary<NSString*, XTType*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        {
        XTBlockNode* b = (XTBlockNode*)node;
        for (XTASTNode* s in b.statements)
            {
            [self collectScalarByteListInitLocalsIn:s into:out];
            }
        break;
        }
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectScalarByteListInitLocalsIn:n.thenBlock into:out];
        [self collectScalarByteListInitLocalsIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        {
        XTWhileNode* w = (XTWhileNode*)node;
        [self collectScalarByteListInitLocalsIn:w.body into:out];
        break;
        }
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectScalarByteListInitLocalsIn:f.loopInit into:out];
        [self collectScalarByteListInitLocalsIn:f.body into:out];
        break;
        }
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        XTType* ty = vd.declaredType;
        if (vd.varName && [self scalarByteListStorableType:ty] && vd.initialiser && vd.initialiser.nodeKind == XTASTNodeKindBlock && ![self byteListAllConstant:(XTBlockNode*)vd.initialiser])
            {
            out[vd.varName] = ty;
            }
        break;
        }
    default:
        break;
        }
    }

#pragma mark - Function / method lowering

// Pre-scan: create the XTIRFunction skeleton and module symbol for
// every function decl with a body. Returns NO if any pre-flight
// type-mapping fails.
- (BOOL)preScanFunction:(XTFunctionDeclNode*)fnDecl
    {
    // A body-less declaration is an `extern` prototype (e.g. the host
    // Stdio's `void _putc(u8);`). Still register a symbol so call sites
    // resolve and the backend emits a `bl`/`JSR` to the external name —
    // `lowerFunction` skips it (no body), so no definition is emitted and
    // the linked runtime (corpus C stub) provides it. A later real
    // definition reuses this symbol via the guard below.
    // Use the sema-mangled name as the IR symbol name. For a NON-
    // overloaded free function this defaults to funcName (no change);
    // for an overload set sema assigns a distinct mangled name per
    // signature (`show__u32`, `show__string`, …). Registering by the
    // plain funcName collided all overloads onto one XTIRFunction, so
    // lowering the second body appended after the first's terminator
    // ("cannot append after terminator"). Call sites already resolve
    // through `resolvedMangledName`, so the names now match.
    NSString* irName = fnDecl.mangledName ?: fnDecl.funcName;
    if ([self.module symbolForName:irName])
        return YES;

    // Multi-return function: register with an aggregate return type.
    // The return type is Agg(L) where L packs all return types as
    // sequential fields. The return statement builds the aggregate
    // via AggBuild; call sites destructure it via AggExtract.
    if (fnDecl.returnTypes.count > 1)
        {
        XTIRLayout* tupleLayout = [self layoutForTupleReturnTypes:fnDecl.returnTypes];
        if (!tupleLayout)
            return YES;
        XTIRType* irRetType = [XTIRType aggWithLayout:tupleLayout];

        NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
        for (XTParamNode* p in fnDecl.parameters)
            {
            XTIRType* t = [self irTypeForASTTypeQuiet:p.paramType];
            if (!t)
                return YES;
            [paramTypes addObject:t];
            }
        [paramTypes addObject:[XTIRType memoryType]];

        XTIRBlock* entry = [[XTIRBlock alloc] init];
        entry.name = @"bb_entry";
        XTIRFunction* irFn = [[XTIRFunction alloc] initWithName:irName
                                                     returnType:irRetType
                                                     paramTypes:paramTypes
                                                     entryBlock:entry];
        XTIRSymbol* sym = [XTIRSymbol functionWithName:irName function:irFn type:nil];
        NSMutableDictionary<NSString*, NSNumber*>* attrs = [@{
            @"cloaked" : @NO,
            @"banked" : @NO,
            @"variadic" : @(fnDecl.isVarArgs),
            @"cabi" : @(XTFnIsCABI(fnDecl))
        } mutableCopy];
        if (fnDecl.isIrq)
            attrs[@"irq"] = @YES;
        if (fnDecl.isVbi)
            attrs[@"vbi"] = @YES;
        // Only when set, like irq/vbi/throws above: an attribute printed on
        // EVERY function would rewrite every golden IR file and every
        // differential's expected text, to say "false" about a property almost
        // nothing has.
        if (fnDecl.forwardsVarargs)
            attrs[@"vaforward"] = @YES;
        if (fnDecl.importPackage.length)
            attrs[[@"pkg_" stringByAppendingString:fnDecl.importPackage]] = @YES;
        // (No expname_ here: a bodyless import can never be mangled — the
        // C-linkage rule bans every overload involving a bodyless member.)
        sym.attributes = attrs;
        [self.module addSymbol:sym];
        return YES;
        }
    XTType* astRetType = fnDecl.returnTypes.firstObject ?: [XTType voidType];
    XTIRType* irRetType = [self irTypeForASTTypeQuiet:astRetType];
    if (!irRetType)
        return YES;
    // main() is conceptually `int main(...)` — it returns an exit code to the OS
    // on every target (the 6502 hands DOS a value too). A `void main` is accepted
    // but lowered as int-returning; every exit path yields 0 (see isIntMain:).
    if ([fnDecl.funcName isEqualToString:@"main"] && irRetType.kind == XTIRTypeKindVoid)
        {
        irRetType = [XTIRType i32Type];
        }

    NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
    for (XTParamNode* p in fnDecl.parameters)
        {
        XTIRType* t = [self irTypeForASTTypeQuiet:p.paramType];
        if (!t)
            return YES;
        [paramTypes addObject:t];
        }
    [paramTypes addObject:[XTIRType memoryType]];

    XTIRBlock* entry = [[XTIRBlock alloc] init];
    entry.name = @"bb_entry";
    XTIRFunction* irFn = [[XTIRFunction alloc] initWithName:irName
                                                 returnType:irRetType
                                                 paramTypes:paramTypes
                                                 entryBlock:entry];
    XTIRSymbol* sym = [XTIRSymbol functionWithName:irName function:irFn type:nil];
    NSMutableDictionary<NSString*, NSNumber*>* attrs = [@{
        @"cloaked" : @NO,
        @"banked" : @NO,
        @"variadic" : @(fnDecl.isVarArgs),
        @"cabi" : @(XTFnIsCABI(fnDecl))
    } mutableCopy];
    if (fnDecl.isIrq)
        attrs[@"irq"] = @YES;
    if (fnDecl.isVbi)
        attrs[@"vbi"] = @YES;
    if (fnDecl.forwardsVarargs)
        attrs[@"vaforward"] = @YES;
    // Call sites read this to decide whether to emit an error check after the
    // call — see lowerCallExpr / emitErrorCheckAfterCallTo:.
    if (fnDecl.throwsError)
        attrs[@"throws"] = @YES;
    // `extern` on a definition = exported (public surface, DFE root); a
    // bodyless declaration's `#package` binding rides as a pkg_<name> key —
    // both plain bools, so they round-trip the IR text's generic attribute
    // machinery unchanged (wasm-target.md §6).
    if (fnDecl.isExported)
        {
        attrs[@"exported"] = @YES;
        // The export label is the SPELLED name even when overload mangling
        // renamed the symbol (task #31: mdLen exported as mdLen__v_u32 and
        // the JS caller silently missed it). A string value cannot ride the
        // bool attribute machinery, so it travels as an expname_<name> KEY —
        // the pkg_<name> trick. Sema guarantees at most one extern per name.
        if (fnDecl.mangledName.length && ![fnDecl.mangledName isEqualToString:fnDecl.funcName])
            attrs[[@"expname_" stringByAppendingString:fnDecl.funcName]] = @YES;
        }
    if (fnDecl.importPackage.length)
        attrs[[@"pkg_" stringByAppendingString:fnDecl.importPackage]] = @YES;
    sym.attributes = attrs;
    [self.module addSymbol:sym];
    return YES;
    }

// Pre-scan: register a DataGlobal symbol for every module-level
// variable declaration. Subsequent function-body lowering resolves
// bare identifier references to these symbols via
// `self.globalsByName`. Skipped silently when the declared type is
// unsupported — the function-body pass will surface a more useful
// diagnostic if the global is actually referenced.
// Best-effort constant-fold of an initialiser expression to an
// int64. Returns NO when the expression isn't shape-foldable
// (function call, identifier reference, complex AST). Caller is
// responsible for sizing/truncating the result to the target
// type's byteWidth.
- (BOOL)tryFoldInitialiserInt:(XTASTNode*)node value:(int64_t*)outVal
    {
    if (!node || !outVal)
        return NO;
    switch (node.nodeKind)
        {
    case XTASTNodeKindLiteralInt:
        *outVal = ((XTLiteralIntNode*)node).intValue;
        return YES;
    case XTASTNodeKindLiteralBool:
        *outVal = ((XTLiteralBoolNode*)node).boolValue ? 1 : 0;
        return YES;
    case XTASTNodeKindLiteralChar:
        *outVal = ((XTLiteralCharNode*)node).charValue;
        return YES;
    case XTASTNodeKindUnaryExpr:
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)node;
        int64_t inner = 0;
        if (![self tryFoldInitialiserInt:u.operand value:&inner])
            return NO;
        switch (u.op)
            {
        case XTUnaryOpNeg:
            *outVal = -inner;
            return YES;
        case XTUnaryOpBitNot:
            *outVal = ~inner;
            return YES;
        case XTUnaryOpLogNot:
            *outVal = !inner;
            return YES;
        default:
            return NO;
            }
        }
    case XTASTNodeKindBinaryExpr:
        {
        XTBinaryExprNode* b = (XTBinaryExprNode*)node;
        int64_t l = 0, r = 0;
        if (![self tryFoldInitialiserInt:b.left value:&l])
            return NO;
        if (![self tryFoldInitialiserInt:b.right value:&r])
            return NO;
        switch (b.op)
            {
        case XTBinaryOpAdd:
            *outVal = l + r;
            return YES;
        case XTBinaryOpSub:
            *outVal = l - r;
            return YES;
        case XTBinaryOpMul:
            *outVal = l * r;
            return YES;
        case XTBinaryOpDiv:
            if (r == 0)
                return NO;
            *outVal = l / r;
            return YES;
        case XTBinaryOpMod:
            if (r == 0)
                return NO;
            *outVal = l % r;
            return YES;
        case XTBinaryOpBitAnd:
            *outVal = l & r;
            return YES;
        case XTBinaryOpBitOr:
            *outVal = l | r;
            return YES;
        case XTBinaryOpBitXor:
            *outVal = l ^ r;
            return YES;
        case XTBinaryOpShl:
            *outVal = l << (r & 63);
            return YES;
        case XTBinaryOpShr:
            *outVal = (int64_t)((uint64_t)l >> (r & 63));
            return YES;
        default:
            return NO;
            }
        }
    case XTASTNodeKindCastExpr:
        return [self tryFoldInitialiserInt:((XTCastExprNode*)node).operand value:outVal];
    default:
        return NO;
        }
    }

// Best-effort constant-fold of an initialiser expression to a double, as the
// float twin of tryFoldInitialiserInt. Handles a float literal, a negated one
// (`-0.25` is UnaryOpNeg over the literal — sema doesn't pre-fold it), and an
// integer constant in a float slot (`float f = 1;`).
- (BOOL)tryFoldInitialiserFloat:(XTASTNode*)node value:(double*)outVal
    {
    if (!node || !outVal)
        return NO;
    switch (node.nodeKind)
        {
    case XTASTNodeKindLiteralFloat:
        {
        NSData* d = ((XTLiteralFloatNode*)node).floatData;
        if (!d.length)
            return NO;
        *outVal = [XTFloatEncoding doubleFromIEEEData:d];
        return YES;
        }
    case XTASTNodeKindUnaryExpr:
        {
        XTUnaryExprNode* u = (XTUnaryExprNode*)node;
        if (u.op != XTUnaryOpNeg)
            return NO;
        double inner = 0.0;
        if (![self tryFoldInitialiserFloat:u.operand value:&inner])
            return NO;
        *outVal = -inner;
        return YES;
        }
    case XTASTNodeKindCastExpr:
        return [self tryFoldInitialiserFloat:((XTCastExprNode*)node).operand
                                       value:outVal];
    default:
        break;
        }
    int64_t iv = 0;
    if (![self tryFoldInitialiserInt:node value:&iv])
        return NO;
    *outVal = (double)iv;
    return YES;
    }

// Pack `value` as `byteCount` little-endian bytes into buf[offset…].
// Callers bounds-check `offset + byteCount` against the buffer length.
- (void)packLE:(int64_t)value
         width:(NSUInteger)byteCount
          into:(uint8_t*)buf
            at:(NSUInteger)offset
    {
    uint64_t u = (uint64_t)value;
    for (NSUInteger i = 0; i < byteCount; i++)
        {
        buf[offset + i] = (uint8_t)(u & 0xFF);
        u >>= 8;
        }
    }

// Pack `value` as `byteCount` little-endian bytes into an NSData.
- (NSData*)packLE:(int64_t)value width:(NSUInteger)byteCount
    {
    uint64_t u = (uint64_t)value;
    NSMutableData* d = [NSMutableData dataWithLength:byteCount];
    uint8_t* p = d.mutableBytes;
    for (NSUInteger i = 0; i < byteCount; i++)
        {
        p[i] = (uint8_t)(u & 0xFF);
        u >>= 8;
        }
    return d;
    }

// Byte size of an aggregate global's data slot. An unsized array
// (`OBJECT tree[] = {…}`, `u8 t[] = 0..8;`) takes its element count
// from the initialiser. 0 means "can't size it" — the caller falls
// back to zero-init.
- (NSUInteger)aggregateInitByteWidth:(XTType*)astTy init:(XTASTNode*)expr
    {
    if (!(astTy.kind == XTTypeKindArray && [astTy isKindOfClass:[XTArrayType class]]))
        return astTy.byteWidth;

    XTArrayType* at = (XTArrayType*)astTy;
    NSUInteger elemW = at.elementType.byteWidth;
    if (elemW == 0)
        return 0;
    NSUInteger count = at.elementCount;
    if (count == 0 && expr.nodeKind == XTASTNodeKindBlock)
        {
        count = ((XTBlockNode*)expr).statements.count;
        }
    else if (count == 0 && expr.nodeKind == XTASTNodeKindRangeExpr)
        {
        XTRangeExprNode* r = (XTRangeExprNode*)expr;
        int64_t s = 0, e = 0;
        if (![self tryFoldInitialiserInt:r.startExpr value:&s])
            return 0;
        if (![self tryFoldInitialiserInt:r.endExpr value:&e])
            return 0;
        int64_t end = r.inclusive ? e + 1 : e;
        count = (end > s) ? (NSUInteger)(end - s) : 0;
        }
    return elemW * count;
    }

// Recursively fold `expr`, interpreted as `astTy`, into buf[offset…].
// Handles arrays, structs, and any nesting of the two — an array of
// structs (`OBJECT tree[] = {{…},{…}};`) descends into each brace group
// and writes each field at its own byte offset. Returns NO when a leaf
// isn't a foldable constant; the caller then discards the buffer and
// falls back to zero-init, so a partial write is harmless.
//
// Leaf widths and formats are the ones the IR layout chose for THIS target
// (the front end is passed -m): a pointer is 2 bytes on arm64 and 3 banked on
// xt6502, a float is xtc's own 5-byte encoding. A backend is free to lay the
// aggregate out differently — arm64 gives a pointer 8 bytes and wants IEEE
// floats — and the native ones do; each re-lays this image into its own
// layout at data-emission time via XTAggInitRelay. So the only thing that
// can't fold is a leaf whose VALUE isn't a compile-time constant (`&other`
// needs a relocation); that returns NO and warns.
- (BOOL)foldInitialiser:(XTASTNode*)expr
                 toType:(XTType*)astTy
                   into:(uint8_t*)buf
                  limit:(NSUInteger)limit
                 offset:(NSUInteger)offset
    {
    if (!expr || !astTy)
        return NO;

    if (astTy.kind == XTTypeKindArray && [astTy isKindOfClass:[XTArrayType class]])
        {
        XTArrayType* at = (XTArrayType*)astTy;
        XTType* elemTy = at.elementType;
        NSUInteger elemW = elemTy.byteWidth;
        if (elemW == 0)
            return NO;

        // Brace list, one entry per element. Entries past the declared
        // length are dropped and a short list leaves the tail zeroed.
        if (expr.nodeKind == XTASTNodeKindBlock)
            {
            NSArray<XTASTNode*>* items = ((XTBlockNode*)expr).statements;
            NSUInteger count = at.elementCount ?: items.count;
            for (NSUInteger i = 0; i < items.count && i < count; i++)
                {
                if (![self foldInitialiser:items[i]
                                    toType:elemTy
                                      into:buf
                                     limit:limit
                                    offset:offset + i * elemW])
                    return NO;
                }
            return YES;
            }
        // Range init (`u8 g_buf[10] = 0..10;`): bake the consecutive
        // element values. Sema guarantees an integer element type.
        if (expr.nodeKind == XTASTNodeKindRangeExpr)
            {
            XTRangeExprNode* r = (XTRangeExprNode*)expr;
            int64_t s = 0, e = 0;
            if (![self tryFoldInitialiserInt:r.startExpr value:&s])
                return NO;
            if (![self tryFoldInitialiserInt:r.endExpr value:&e])
                return NO;
            int64_t end = r.inclusive ? e + 1 : e;
            if (end < s)
                end = s;
            NSUInteger count = at.elementCount ?: (NSUInteger)(end - s);
            for (NSUInteger i = 0; i < count; i++)
                {
                NSUInteger off = offset + i * elemW;
                if (off + elemW > limit)
                    return NO;
                [self packLE:s + (int64_t)i width:elemW into:buf at:off];
                }
            return YES;
            }
        return NO;
        }

    // Struct: one brace entry per field, each written at the field's own
    // byte offset (fields are tightly packed, in declaration order).
    if (astTy.kind == XTTypeKindStruct && [astTy isKindOfClass:[XTStructType class]] && expr.nodeKind == XTASTNodeKindBlock)
        {
        XTStructType* st = (XTStructType*)astTy;
        NSArray<XTASTNode*>* items = ((XTBlockNode*)expr).statements;
        for (NSUInteger i = 0; i < items.count && i < st.fields.count; i++)
            {
            XTStructField* f = st.fields[i];
            if (![self foldInitialiser:items[i]
                                toType:f.fieldType
                                  into:buf
                                 limit:limit
                                offset:offset + f.byteOffset])
                return NO;
            }
        return YES;
        }

    NSUInteger width = astTy.byteWidth;
    if (width == 0 || offset + width > limit)
        return NO;

    // Scalar leaf. A brace/bracket list on a scalar is the raw byte-list
    // form (`u16 gA = {$37, $13};`, `float f = [$00, $00, $6A, $09, $E6];`)
    // — one byte per entry, already in the target's format, so it holds
    // for float leaves too.
    if (expr.nodeKind == XTASTNodeKindBlock)
        {
        NSArray<XTASTNode*>* items = ((XTBlockNode*)expr).statements;
        for (NSUInteger i = 0; i < items.count && i < width; i++)
            {
            int64_t bv = 0;
            if (![self tryFoldInitialiserInt:items[i] value:&bv])
                return NO;
            buf[offset + i] = (uint8_t)(bv & 0xFF);
            }
        return YES;
        }

    // A float leaf is baked in xtc's own float format — the 5/8-byte encoding
    // the lexer already produced — filling the slot the IR layout gave it. A
    // backend with native IEEE floats re-encodes it on the way out
    // (XTAggInitRelay); xt6502's format IS this one, so it round-trips.
    if (astTy.kind == XTTypeKindFloat || astTy.kind == XTTypeKindDouble)
        {
        double v = 0.0;
        if (![self tryFoldInitialiserFloat:expr value:&v])
            return NO;
        // Encode in the TARGET's float format, at the slot's own width — the
        // front end is told the target, so it can. (Truncating xtc's 5-byte
        // encoding into a 4-byte IEEE slot silently dropped a mantissa byte:
        // 3.14159 came back as 3.141571.)
        NSData* fd = nil;
        if ([XTType floatIsIEEE])
            {
            if (width == 8)
                {
                uint64_t bits = 0;
                memcpy(&bits, &v, sizeof(bits));
                fd = [self packLE:(int64_t)bits width:8];
                }
            else
                {
                float f = (float)v;
                uint32_t bits = 0;
                memcpy(&bits, &f, sizeof(bits));
                fd = [self packLE:(int64_t)(uint64_t)bits width:4];
                }
            }
        else
            {
            fd = (width == 8) ? [XTFloatEncoding encodeDoubleDouble:v]
                              : [XTFloatEncoding encodeDouble:v];
            }
        memcpy(buf + offset, fd.bytes, MIN(width, fd.length));
        return YES;
        }

    // A pointer leaf folds like any other integer, at the width XTPointerType
    // gives it for THIS target (2 on arm64, 3 banked on xt6502) — the front
    // end is told the target, so the IR image is already right. A backend that
    // uses a wider pointer re-lays the image into its own layout on the way
    // out (XTAggInitRelay), so `{$1234, 0}` for a struct with a null link
    // works everywhere. A non-null address still can't fold: `&other` isn't a
    // foldable integer, so it falls out below and warns.
    int64_t v = 0;
    if (![self tryFoldInitialiserInt:expr value:&v])
        return NO;
    [self packLE:v width:width into:buf at:offset];
    return YES;
    }

// Top-level entry: produce the global's constant initial bytes, or
// nil when the expression isn't foldable.
//
// Integer globals get LE-packed bytes of length `astTy.byteWidth`;
// aggregates recurse through foldInitialiser above.
// FLOAT/DOUBLE globals are stored format-NEUTRALLY: the abstract
// numeric value as 8 raw IEEE-754 double bits (LE). Each backend
// re-encodes that to its own float format at data-emission time
// (xt6502: xtc 5/8-byte via XTFloatEncoding; arm64: native IEEE
// single/double) — the same neutrality the float Const observes.
- (nullable NSData*)tryFoldInitialiser:(XTASTNode*)expr toType:(XTType*)astTy
    {
    if (!expr || !astTy)
        return nil;
    // Aggregate init (`u8 t[8] = {$80, …}` for the gfx lookup tables,
    // `OBJECT tree[] = {{…},{…}}` for a struct table, `u8 b[10] = 0..10`).
    // Without this a global aggregate initialiser doesn't fold → the slot
    // silently zero-inits and the table reads back as zeros at runtime
    // (task #59). A non-const leaf returns nil (falls back to zero-init).
    if (astTy.kind == XTTypeKindArray || astTy.kind == XTTypeKindStruct)
        {
        NSUInteger total = [self aggregateInitByteWidth:astTy init:expr];
        if (total == 0)
            return nil;
        NSMutableData* out = [NSMutableData dataWithLength:total];
        if (![self foldInitialiser:expr
                            toType:astTy
                              into:out.mutableBytes
                             limit:total
                            offset:0])
            return nil;
        return out;
        }
    // Scalar byte-list init (`u16 gA = {$37, $13};`, `float f = [$00, $00,
    // $6A, $09, $E6];`): pack each constant byte entry directly into the
    // scalar's slot, zero-filling missing trailing bytes.
    if (expr.nodeKind == XTASTNodeKindBlock)
        {
        NSUInteger width = astTy.byteWidth;
        if (width == 0)
            return nil;
        NSMutableData* out = [NSMutableData dataWithLength:width];
        if (![self foldInitialiser:expr
                            toType:astTy
                              into:out.mutableBytes
                             limit:width
                            offset:0])
            return nil;
        return out;
        }
    if (astTy.kind == XTTypeKindFloat || astTy.kind == XTTypeKindDouble)
        {
        if (expr.nodeKind != XTASTNodeKindLiteralFloat)
            return nil;
        NSData* d = ((XTLiteralFloatNode*)expr).floatData;
        double value = [XTFloatEncoding doubleFromIEEEData:d];
        uint64_t raw = 0;
        memcpy(&raw, &value, sizeof(raw));
        return [self packLE:(int64_t)raw width:8];
        }
    NSUInteger width = astTy.byteWidth;
    if (width == 0)
        return nil;
    int64_t value = 0;
    if (![self tryFoldInitialiserInt:expr value:&value])
        return nil;
    return [self packLE:value width:width];
    }

- (void)preScanGlobalVariable:(XTVariableDeclNode*)decl
    {
    if (!decl.varName.length)
        return;
    if (self.globalsByName[decl.varName])
        return;
    if ([self.module symbolForName:decl.varName])
        return;

    XTType* astTy = decl.declaredType;
    if (!astTy)
        return;
    XTIRType* irTy = [self irTypeForASTTypeQuiet:astTy];
    if (!irTy)
        return;
    // A WEAK global is a weak slot: it carries two hidden link words before its
    // payload, exactly as a weak ivar or local does, so the runtime finds the
    // chain links at a fixed negative offset. Without them it would write
    // slot[-1]/slot[-2] over the NEIGHBOURING GLOBAL.
    // Every access goes through globalPayloadAddr:.
    if ([self astTypeIsWeakSlot:astTy])
        {
        irTy = [self weakSlotAggFor:irTy];
        self.weakGlobals[decl.varName] = astTy;
        }

    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:decl.varName
                                                type:irTy
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    // `extern` WITH an initialiser (§6) = an exported definition: this
    // module owns the storage and publishes it (on wasm32 the global's
    // linear-memory address exports; ordinary external linkage elsewhere).
    if (decl.isExported)
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, @"exported" : @YES};
    else
        sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    // `extern` — defined in another module. Emit a reference, reserve no storage.
    if (decl.isExternalGlobal)
        sym.isExternalGlobal = YES;
    if (decl.initialiser && !decl.isExternalGlobal)
        {
        NSData* bytes = [self tryFoldInitialiser:decl.initialiser toType:astTy];
        if (bytes)
            {
            sym.initialBytes = bytes;
            }
        else
            {
            // Not foldable — a string literal initialiser is an ADDRESS, a
            // float leaf has no integer image, an expression has no image at
            // all. Deferred: main's prologue runs these as ordinary stores
            // (the base32-alphabet report — `u8* ALPHA = \"…\";` warned and
            // then read back null, which crashed the first subscript). Only
            // a module that never lowers a main falls back to the warning,
            // at the end of lowering. A WEAK slot stays on the warning path:
            // its payload sits past hidden link words the plain store below
            // would clobber, and a weak global initialised from a literal is
            // not a shape anyone has asked to mean something.
            if ([self astTypeIsWeakSlot:astTy])
                {
                [self.diag emitWarning:[NSString stringWithFormat:
                                                     @"global '%@' initialiser is not constant-foldable — the slot is "
                                                     @"zero-initialised and will read back as zeros at runtime",
                                                     decl.varName]
                                    at:decl.location];
                }
            else
                {
                [self.pendingGlobalInits addObject:decl];
                }
            }
        }
    XTIRSymbolId sid = [self.module addSymbol:sym];
    self.globalsByName[decl.varName] = @(sid);
    }

// Generic body-lowering helper: drives the per-function state machine
// (params, entry block, body walk, void-return synthesis) for both
// free functions and class methods. The `preBoundSelf` argument is the
// SSA value for the implicit `self` formal — non-nil only when lowering
// an instance method.
- (void)_lowerCallable:(XTIRFunction*)fn
            paramNames:(NSArray<NSString*>*)paramNames
                  body:(XTASTNode*)body
          preBoundSelf:(nullable NSString*)selfName
    {
    [self.module addFunction:fn];

    self.currentFunction = fn;
    self.locals = [NSMutableDictionary dictionary];
    self.strongLocals = [NSMutableSet set];
    self.strongArrayLocals = [NSMutableDictionary dictionary];
    self.weakArrayLocals = [NSMutableDictionary dictionary];
    self.strongStructLocals = [NSMutableDictionary dictionary];
    self.strongStructArrayLocals = [NSMutableDictionary dictionary];
    self.heapArrayLengthByLocal = [NSMutableDictionary dictionary];
    self.ownedTemps = [NSMutableArray array]; // ARC +1 temp sweep (#123)
    self.ownedTempBlocks = [NSMutableArray array];
    self.ownedTempDepths = [NSMutableArray array];
    // Cleared PER FUNCTION. Value ids are allocated per function, so a map
    // that outlives one is a map whose keys mean something else: the
    // return-exemption walk followed a stale entry into another function's
    // values, and a strong local whose id happened to match went unreleased.
    // Found by the self-hosted port, which uses object identity and so could
    // not reproduce it (#872-class).
    self.bitcastSource = [NSMutableDictionary dictionary];
    self.condDepth = 0;
    self.arcScopeStack = [NSMutableArray array];
    self.loopStack = [NSMutableArray array];
    self.pinnedLocals = [NSMutableDictionary dictionary];
    self.pinnedParamInit = [NSMutableDictionary dictionary];
    self.pinnedLocalASTType = [NSMutableDictionary dictionary];
    self.weakPinnedLocals = [NSMutableSet set];
    self.pinnedLocalsByType = [NSMutableDictionary dictionary];
    self.valueClassLocals = [NSMutableDictionary dictionary];
    // Undo any globalsByName bindings the PREVIOUS function's static
    // locals installed, so a static's name doesn't leak into siblings.
    [self.staticLocalSaved enumerateKeysAndObjectsUsingBlock:
                               ^(NSString* name, id prior, BOOL* stop) {
                                 if (prior == [NSNull null])
                                     [self.globalsByName removeObjectForKey:name];
                                 else
                                     self.globalsByName[name] = prior;
                               }];
    self.staticLocalSaved = [NSMutableDictionary dictionary];
    self.arrayLocalNames = [NSMutableSet set];
    self.arrayLocalElementType = [NSMutableDictionary dictionary];
    self.aborted = NO;

    XTIRDefSite* paramDef = [XTIRDefSite parameterDef];
    XTIRValue* selfValue = nil;
    for (NSUInteger i = 0; i < fn.paramTypes.count; i++)
        {
        XTIRValueId vid = [fn allocateValueId];
        XTIRValue* v = [[XTIRValue alloc] initWithValueId:vid
                                                     type:fn.paramTypes[i]
                                                  defSite:paramDef];
        [fn registerValue:v];
        if (i < paramNames.count)
            {
            NSString* pname = paramNames[i];
            self.locals[pname] = v;
            if (selfName && [pname isEqualToString:selfName])
                {
                selfValue = v;
                }
            // Value-typed struct parameter — an aggregate can't be an
            // SSA scalar, so member access (`p.x`, `&p.x`) must resolve
            // through its address. The param value-id ALREADY has a
            // backend slot (the prologue allocates + spills every
            // param), so register it as a pinned local pointing at that
            // same value-id; AddrOf-of-pinned resolves via
            // slotForValueId:. Do NOT add it to fn.frameInfo.pinnedLocals
            // / pinnedLocalSize — it lives in the param slot, not the
            // frame-locals region, and counting it there would
            // double-allocate and break the §12.11 frame invariant.
            // (`self` is a class self-pointer, never an Agg.)
            if (fn.paramTypes[i].kind == XTIRTypeKindAgg)
                {
                XTIRPinnedLocal* pl = [[XTIRPinnedLocal alloc]
                    initWithName:pname
                            type:fn.paramTypes[i]
                      byteOffset:0
                         valueId:vid];
                self.pinnedLocals[pname] = pl;
                }
            }
        else
            {
            self.memToken = v;
            }
        }
    self.currentSelf = selfValue;

    // Pre-scan the body for `&<identifier>` references. Each
    // address-taken local gets pinned: allocated a value-id +
    // an XTIRPinnedLocal entry in fn.frameInfo so AddrOf-by-Use
    // operands can reference it later. Reads / writes of pinned
    // locals are routed through Load/Store on the pinned slot
    // (handled at the use sites; pinning here just sets up the
    // book-keeping).
    [self preScanAddressTakenLocalsIn:body fn:fn];

    self.currentBlock = fn.entryBlock;

    // Copy each `&`-taken scalar/pointer parameter into its own frame slot,
    // once, before any user statement. From here reads/writes of the name route
    // through the pinned slot (lowerIdentifier checks pinnedLocals first), so the
    // param SSA value is read exactly here — and `AddrOf name` targets the slot,
    // not the param value. This is what makes such a function safe to inline
    // (bug 202). Sorted by name for a deterministic prologue order across both
    // compilers.
    if (self.pinnedParamInit.count)
        {
        NSArray<NSString*>* pnames =
            [self.pinnedParamInit.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString* pn in pnames)
            {
            XTIRPinnedLocal* pl = self.pinnedLocals[pn];
            XTIRValue* pv = self.pinnedParamInit[pn];
            if (!pl || !pv)
                continue;
            XTIRType* ptrTy = nil;
            XTIRValue* addr = [self pinnedAddr:pl name:pn outType:&ptrTy];
            if (addr)
                [self emitStore:addr value:pv];
            }
        }

    // Deferred global initialisers (see pendingGlobalInits): main's prologue
    // is the earliest point every target reaches exactly once, before any
    // user statement can read the global. A class-typed initialiser's +1 is
    // ADOPTED by the global (stored without an extra retain), which is the
    // ownership a global holds until process exit.
    if ([fn.name isEqualToString:@"main"] && self.pendingGlobalInits.count)
        {
        NSArray<XTVariableDeclNode*>* pend = [self.pendingGlobalInits copy];
        [self.pendingGlobalInits removeAllObjects];
        for (XTVariableDeclNode* g in pend)
            {
            NSNumber* sid = self.globalsByName[g.varName];
            if (!sid)
                continue;
            // An ARRAY initialiser `{ … }` whose elements aren't constant-
            // foldable (symbol addresses): store each element into the slot,
            // coercing per element. This WIDENS `callback tab[N] = {&a,&b}` to
            // {recv,code} pairs and stores `pointer p[N] = {&a,&b}` addresses —
            // the scalar path below can't lower the brace list (it reaches
            // lowerExpression as an unsupported aggregate). Bug 167 / c2xc 11.
            if (g.declaredType.kind == XTTypeKindArray && [g.declaredType isKindOfClass:[XTArrayType class]] && g.initialiser.nodeKind == XTASTNodeKindBlock)
                {
                XTArrayType* at = (XTArrayType*)g.declaredType;
                XTType* elemAST = at.elementType;
                // A callback (and any `weak:` element) is an auto-zeroing SLOT
                // — {prev, next, payload} — so the element STRIDE spans the two
                // link words and the value lands at the payload (field 2), the
                // same shape emitSubscriptAddress reads back. Mirror it exactly
                // or the store and the `tab[i](…)` read disagree on the layout.
                XTType* weakElem = [self astTypeIsWeakSlot:elemAST] ? elemAST : nil;
                XTIRType* payloadIR = [self irTypeForASTTypeQuiet:elemAST];
                XTIRType* elemIR = weakElem ? [self weakSlotAggFor:payloadIR] : payloadIR;
                XTIRType* aslotTy = [self irTypeForASTTypeQuiet:g.declaredType];
                if (elemIR && payloadIR && aslotTy)
                    {
                    XTIRType* elemPtr = [XTIRType ptrToType:elemIR
                                                     window:XTIRWindowUnbanked];
                    XTIRType* payloadPtr = [XTIRType ptrToType:payloadIR
                                                        window:XTIRWindowUnbanked];
                    XTIRValue* slotAddr = [self emitInsnOpcode:XTIROpAddrOf
                                                        result:[XTIRType ptrToType:aslotTy window:XTIRWindowUnbanked]
                                                      operands:@[ [XTIROperand symWithSymbolId:
                                                                                   (XTIRSymbolId)sid.unsignedIntegerValue] ]];
                    XTIRValue* base = [self emitInsnOpcode:XTIROpBitcast
                                                    result:elemPtr
                                                  operands:@[ [XTIROperand useWithValueId:slotAddr.valueId] ]];
                    NSArray<XTASTNode*>* items = ((XTBlockNode*)g.initialiser).statements;
                    NSUInteger count = at.elementCount ?: items.count;
                    for (NSUInteger i = 0; i < items.count && i < count; i++)
                        {
                        XTIRValue* ev = [self lowerExpression:items[i]];
                        if (!ev)
                            continue;
                        ev = [self coerceValue:ev
                                      fromType:items[i].resolvedType
                                        toType:elemAST
                                      location:g.location];
                        if (!ev)
                            continue;
                        XTIRValue* idxC = [self emitU16Const:(uint16_t)i];
                        XTIRValue* ea = [self emitInsnOpcode:XTIROpElementAddr
                                                      result:elemPtr
                                                    operands:@[ [XTIROperand useWithValueId:base.valueId],
                                                                [XTIROperand useWithValueId:idxC.valueId] ]];
                        // Past the two link words to the payload, as the read does.
                        if (ea && weakElem)
                            ea = [self emitFieldAddr:ea fieldIndex:2 resultType:payloadPtr];
                        if (ea)
                            [self emitStore:ea value:ev];
                        }
                    continue;
                    }
                }
            XTIRValue* v = [self lowerExpression:g.initialiser];
            if (!v)
                continue;
            v = [self coerceValue:v
                         fromType:g.initialiser.resolvedType
                           toType:g.declaredType
                         location:g.location];
            if (!v)
                continue;
            XTIRType* slotTy = [self irTypeForASTTypeQuiet:g.declaredType];
            if (!slotTy)
                continue;
            XTIRValue* addr = [self emitInsnOpcode:XTIROpAddrOf
                                            result:[XTIRType ptrToType:slotTy window:XTIRWindowUnbanked]
                                          operands:@[ [XTIROperand symWithSymbolId:
                                                                       (XTIRSymbolId)sid.unsignedIntegerValue] ]];
            [self emitStore:addr value:v];
            }
        }

    // Static-method self: bind currentSelf to the address of the
    // class's `__sdata` block so ivar reads/writes reuse the instance
    // FieldAddr machinery. (Instance methods bound currentSelf from
    // the `self` param above.)
    if (self.staticSelfClassName && self.currentClassInfo)
        {
        XTIRSymbolId sid = [self staticDataSymbolForClass:self.currentClassInfo];
        XTIRValue* sdataSelf = [self emitInsnOpcode:XTIROpAddrOf
                                             result:self.currentClassInfo.selfPtrType
                                           operands:@[ [XTIROperand symWithSymbolId:sid] ]];
        self.currentSelf = sdataSelf;
        }

    // ARC 2d: retain `self` on entry so it survives the body even if the
    // caller drops its only reference mid-call. Released at every scope
    // exit by releaseStrongLocalsAlongReturnExcept:. Gated by the caller
    // (heap receiver only, non-static, non-destructor); static `self`
    // (an __sdata address) is never retained.
    self.currentRetainedSelf = nil;
    if (self.pendingRetainSelf && self.currentSelf && !self.staticSelfClassName)
        {
        [self emitRetain:self.currentSelf];
        self.currentRetainedSelf = self.currentSelf;
        }
    self.pendingRetainSelf = NO;

    // ARC, private:docs/bugs/064: a class-pointer PARAMETER that the body ASSIGNS owns
    // whatever it holds, so it is retained here and released on every exit.
    //
    // Left borrowed, `p = someStrongLocal` bound the local's object into the
    // parameter with no retain — the local still owned it, and its scope-exit
    // release deallocated the object the parameter was about to be read
    // through. Retaining only AT the assignment cannot fix it either: when the
    // assignment is conditional the slot still holds the caller's borrowed
    // argument on the other path, and an unconditional scope-exit release
    // would then over-release it. Owning from entry is the only shape that is
    // right on both paths — and it is exactly what the `self` retain above
    // already does, for the same reason.
    //
    // The count balances however many times the parameter is rebound: the
    // first assignment releases this entry retain, each later one releases its
    // predecessor, and the scope exit releases the last.
    self.pendingStrongParams = [NSMutableArray array];
    for (NSString* pname in paramNames)
        {
        if (selfName && [pname isEqualToString:selfName])
            continue;
        if (![self.preScanAssignedNames containsObject:pname])
            continue;
        XTIRValue* pv = self.locals[pname];
        if (!pv)
            continue;
        [self emitRetain:pv];
        [self.pendingStrongParams addObject:pname];
        }

    // Auto-synthesised `super.init()`: a subclass init that omits the
    // super call gets a parent-first call injected here, after `self` is
    // bound and before the user body, so parent ivars are valid when the
    // subclass code runs. Mirrors the dealloc super-chain (which appends
    // at every return); init prepends once. (private:docs/bugs/011 #1)
    if (self.pendingAutoSuperInitTarget)
        {
        NSString* target = self.pendingAutoSuperInitTarget;
        self.pendingAutoSuperInitTarget = nil;
        XTIRSymbol* psym = [self.module symbolForName:target];
        if (psym && self.currentSelf)
            {
            XTIRSymbolId sid = [self.module.symbols indexOfObjectIdenticalTo:psym];
            XTIRCallConv* conv = psym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
                                 : psym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                                                        : [XTIRCallConv standard];
            (void)[self emitCall:sid
                        callConv:conv
                       argValues:@[ self.currentSelf ]
                      resultType:nil];
            }
        }

    [self lowerStatement:body];

    if (self.aborted)
        {
        // The body bailed out on an unsupported construct. Reset the
        // function to a single-block stub terminated by Unreachable
        // so the verifier accepts the module. The function symbol
        // stays valid — call sites still resolve, and the backend
        // (task #18+) is where the residual reasons surface.
        [self abandonCurrentFunction];
        }
    else if (!self.currentBlock.terminator && [self isIntMain:fn])
        {
        // main() fell off the end — normalised `void main` (or a returnless
        // path) exits with code 0.
        [self releaseStrongLocalsAlongReturnExcept:nil];
        XTIRValue* z = [self emitMainExitZero];
        [self emitTerminator:XTIROpReturn
                    operands:@[ [XTIROperand useWithValueId:z.valueId],
                                [XTIROperand useWithValueId:self.memToken.valueId] ]];
        }
    else if (!self.currentBlock.terminator && fn.returnType.kind == XTIRTypeKindVoid)
        {
        [self releaseStrongLocalsAlongReturnExcept:nil];
        [self emitTerminator:XTIROpReturn
                    operands:@[ [XTIROperand useWithValueId:self.memToken.valueId] ]];
        }
    else if (!self.currentBlock.terminator)
        {
        // Non-void body fell off the end without an explicit return.
        // The frontend should diagnose this as a sema error, but in
        // case it doesn't (or the body did some hairy thing) we still
        // need a terminator for the verifier.
        [self emitTerminator:XTIROpUnreachable operands:@[]];
        }

    self.currentFunction = nil;
    self.currentBlock = nil;
    self.locals = nil;
    self.memToken = nil;
    self.currentSelf = nil;
    self.strongLocals = nil;
    self.arcScopeStack = nil;
    self.loopStack = nil;
    self.pinnedLocals = nil;
    self.pinnedLocalsByType = nil;
    self.valueClassLocals = nil;
    }

// Reset the current function's body to a single Unreachable-
// terminated entry block. Used when lowering hit a soft-fail and we
// need the function to still pass the verifier so the rest of the
// module can move on to the next pipeline stage.
- (void)abandonCurrentFunction
    {
    // Reset the function's body to a single Return-terminated entry
    // block. The earlier shape installed `Unreachable` here, which
    // matched the IR-SPEC's "the optimiser may delete this code"
    // intent but had a horrible runtime consequence: every caller
    // of an abandoned method landed on BRK and crashed. Returning
    // a zero of the function's return type lets callers continue,
    // which is what task #22 needed to move ~30 fixtures off the
    // `runtime` bucket.
    //
    // The abandoned function is still semantically wrong (the
    // user's body was supposed to do something), but "wrong
    // output" is a better residue than "crashing binary" — the
    // corpus's `rc != 0` check turns into `rc == 0` and the
    // fixture passes the "does it complete" measurement.
    XTIRFunction* fn = self.currentFunction;
    if (!fn)
        return;
    XTIRBlock* entry = fn.entryBlock;
    [entry.phiNodes removeAllObjects];
    [entry.instructions removeAllObjects];
    [entry resetTerminator];

    // Find the mem token — it's the last parameter of the function,
    // already registered as a value at the (paramCount - 1) value id.
    XTIRValue* memToken = nil;
    if (fn.paramTypes.count > 0 && [fn.paramTypes.lastObject kind] == XTIRTypeKindMemory)
        {
        memToken = [fn valueForId:(XTIRValueId)(fn.paramTypes.count - 1)];
        }

    NSMutableArray<XTIROperand*>* retOperands = [NSMutableArray array];
    if (fn.returnType.kind != XTIRTypeKindVoid)
        {
        // Materialise a zero of the return type and use it as the
        // return value. Pointer returns get an IntToPtr of zero.
        XTIRType* rt = fn.returnType;
        XTIRDefSite* site = [[XTIRDefSite alloc] initWithBlock:entry insnIndex:0];
        XTIRValueId vid = [fn allocateValueId];
        XTIRValue* zero = [[XTIRValue alloc] initWithValueId:vid type:rt defSite:site];
        [fn registerValue:zero];
        if (rt.kind == XTIRTypeKindPtr)
            {
            // Const #0:U16 + IntToPtr to result type.
            XTIRValueId iv = [fn allocateValueId];
            XTIRValue* intZero = [[XTIRValue alloc] initWithValueId:iv
                                                               type:[XTIRType u16Type]
                                                            defSite:site];
            [fn registerValue:intZero];
            XTIRInsn* iz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:intZero
                                                   operands:@[ [XTIROperand immIWithType:[XTIRType u16Type]
                                                                                   value:0] ]
                                                     dbgLoc:nil];
            [entry appendInstruction:iz];
            XTIRInsn* cast = [[XTIRInsn alloc] initWithOpcode:XTIROpIntToPtr
                                                       result:zero
                                                     operands:@[ [XTIROperand useWithValueId:intZero.valueId] ]
                                                       dbgLoc:nil];
            [entry appendInstruction:cast];
            }
        else
            {
            XTIRInsn* cz = [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:rt value:0] ]
                                                     dbgLoc:nil];
            [entry appendInstruction:cz];
            }
        [retOperands addObject:[XTIROperand useWithValueId:zero.valueId]];
        }
    if (memToken)
        {
        [retOperands addObject:[XTIROperand useWithValueId:memToken.valueId]];
        }
    XTIRInsn* ret = [[XTIRInsn alloc] initWithOpcode:XTIROpReturn
                                              result:nil
                                            operands:retOperands
                                              dbgLoc:nil];
    [entry setTerminator:ret];

    while (fn.blocks.count > 1)
        {
        [fn.blocks removeLastObject];
        }
    }

- (void)lowerFunction:(XTFunctionDeclNode*)fnDecl
    {
    if (!fnDecl.body)
        return;
    // Look the function up by the same name preScanFunction registered it
    // under — the sema-mangled name (== funcName when not overloaded).
    XTIRSymbol* sym = [self.module symbolForName:(fnDecl.mangledName ?: fnDecl.funcName)];
    XTIRFunction* fn = sym.function;
    if (!fn)
        return; // pre-scan failed; diagnostics already emitted

    // A load-time constructor (the XG-NIB factory registration) records its name
    // so the backend emits it into the target's constructor list.
    if (fnDecl.isModuleInit &&
        ![self.module.moduleInitFunctionNames containsObject:fn.name])
        {
        [self.module.moduleInitFunctionNames addObject:fn.name];
        }

    NSMutableArray<NSString*>* paramNames = [NSMutableArray array];
    for (XTParamNode* p in fnDecl.parameters)
        {
        [paramNames addObject:p.paramName];
        }
    self.currentFnThrows = fnDecl.throwsError;
    [self _lowerCallable:fn
              paramNames:paramNames
                    body:fnDecl.body
            preBoundSelf:nil];
    }

#pragma mark - Class lowering

// Compute the instance and vtable layouts for `cls`, derive the ivar
// offset / method slot maps, and register the vtable symbol in the
// module. Recurses into the parent chain first so parent layouts and
// slot indices come first (per `doc/inheritance.md` §4).
// Class-name → XTIRClassInfo, pre-scanning ON DEMAND when the pre-scan
// loop hasn't reached the class yet. A cyclic #import reorders the merged
// unit so a class's USER can pre-scan first; without this its `T*`
// parameter/ivar types silently mapped to Ptr(Void), and the -O2 leaf
// inliner then spliced accessor bodies whose FieldAddr base had no layout
// — every field offset folded to 0, with no diagnostic (task #20).
- (nullable XTIRClassInfo*)classInfoResolvingName:(NSString*)name
    {
    XTIRClassInfo* ci = self.classesByName[name];
    if (ci)
        return ci;
    if ([self.preScanInProgress containsObject:name])
        return nil;
    XTClassDeclNode* decl = self.classDeclsByName[name];
    if (!decl)
        return nil;
    // Phase 1 only. Running the FULL pre-scan here would nest this class's
    // signature loop inside whichever signature loop triggered us, and a
    // signature met while a third class is mid-layout collapses to
    // Ptr(Void) — string_charset caught exactly that. The layout (and so
    // selfPtrType) is all a type needs; the driver loop finishes phase 2.
    return [self preScanClassLayout:decl];
    }

// The pre-scan is TWO phases so that resolving a class-pointer type on
// demand (above) never runs signature/vtable code re-entrantly:
//   phase 1 (preScanClassLayout:) — instance layout + selfPtrType, the
//     only things a TYPE needs; registers in classesByName at its end.
//   phase 2 (preScanClassRest:)   — vtable, itables, category chain and
//     method symbols/skeletons; parent-first, memoized, run by
//     preScanClass: (the driver loop) once phase 1 exists for everyone
//     it pulls in.
- (XTIRClassInfo*)preScanClass:(XTClassDeclNode*)cls
    {
    XTIRClassInfo* info = [self preScanClassLayout:cls];
    [self preScanClassRest:cls info:info];
    return info;
    }

- (XTIRClassInfo*)preScanClassLayout:(XTClassDeclNode*)cls
    {
    XTIRClassInfo* cached = self.classesByName[cls.className];
    if (cached)
        return cached;
    [self.preScanInProgress addObject:cls.className];

    XTIRClassInfo* parentInfo = nil;
    if (cls.parentClass)
        {
        parentInfo = [self preScanClassLayout:cls.parentClass];
        }
    else if (cls.parentName)
        {
        XTClassDeclNode* parentDecl = self.classDeclsByName[cls.parentName];
        if (parentDecl)
            parentInfo = [self preScanClassLayout:parentDecl];
        }

    XTIRClassInfo* info = [[XTIRClassInfo alloc] init];
    info.className = cls.className;
    info.classId = self.classIdByName[cls.className].unsignedIntegerValue;
    info.parent = parentInfo;
    // A class needs a vtable when it conforms to a protocol, inherits a
    // vtable, OR participates in ≥1 virtual slot (sema stamps
    // cls.vtableMethodSlots for inheritance overrides too — task #110). A
    // class with no protocol, no vtable parent, and no overridden method
    // keeps vtableMethodSlots empty, so needsVtable stays NO: no per-object
    // vtable pointer, byte-identical output, non-overridden methods stay
    // statically dispatched.
    info.usedByNew = cls.usedByNew;
    info.needsVtable = (cls.protocolNames.count > 0) || (parentInfo && parentInfo.needsVtable) || (cls.vtableMethodSlots.count > 0);
    info.ivarFieldIndex = [NSMutableDictionary dictionary];
    info.ivarASTType = [NSMutableDictionary dictionary];
    info.staticIvarSymbol = [NSMutableDictionary dictionary];
    info.methodSlot = [NSMutableDictionary dictionary];
    info.methodMangled = [NSMutableDictionary dictionary];
    info.methodReturnAST = [NSMutableDictionary dictionary];

    // -- Instance layout: vtable pointer at slot 0, then ivars
    // (parent's first by inheritance order).
    NSMutableArray<XTIRLayoutField*>* instanceFields = [NSMutableArray array];
    uint32_t instOffset = 0;
    XTIRType* vtblPtrType = [XTIRType ptrToType:[XTIRType voidType]
                                         window:XTIRWindowUnbanked];
    [instanceFields addObject:[[XTIRLayoutField alloc] initWithOffset:instOffset
                                                                 type:vtblPtrType]];
    // The slot is a POINTER, so it is as wide as a pointer on this target —
    // 8 on arm64/x86_64/win64, 4 on arm9/m68k, 3 on xt6502. It used to be
    // hardcoded at 2, which broke the type-width invariant in the one place
    // nobody looks: `instanceLayout.size` is what `new` passes the allocator
    // and what `delete obj[]` uses as its stride, while the backend addresses
    // fields with its OWN widths. Every arm64 object was six bytes short of
    // what the backend wrote to, and allocator rounding absorbed it for every
    // class small enough — until a class with a large array ivar put its last
    // ivar past the rounded-up block and the next allocation overwrote it
    // (tests/fixtures/class_ivar_after_array.xc). On xt6502 the 3-byte vtable
    // store had been spilling one byte into the first ivar, which `init`
    // happened to overwrite immediately afterwards.
    instOffset += (uint32_t)[XTPointerType heapPointerWidth];
    NSUInteger fieldIndex = 1;

    // Walk parent ivars first, in root-first order.
    NSMutableArray<XTClassDeclNode*>* chain = [NSMutableArray array];
    for (XTClassDeclNode* c = cls.parentClass; c != nil; c = c.parentClass)
        {
        [chain insertObject:c atIndex:0];
        }
    // Ivars follow the same (capped) natural alignment rule as struct fields
    // (blewit #5); the class's own alignment is the max over its slots, and
    // the instance size tail-rounds to it so `new T[N]` strides correctly.
    // Cap 1 (xt6502, and unconfigured unit tests) reproduces the old tightly
    // packed layout bit-for-bit, including the absent tail rounding.
    NSUInteger instAlign = [XTStructType fieldAlignmentForType:
                                             [XTPointerType pointerToType:[XTType u8Type]]];
    for (XTClassDeclNode* ancestor in chain)
        {
        for (XTVariableDeclNode* ivar in ancestor.ivars)
            {
            // A `static` ivar has no per-instance slot anywhere in the chain;
            // the ancestor's own registration owns its global.
            if (ivar.isStatic)
                continue;
            XTType* ivarType = ivar.declaredType ?: [XTType u8Type];
            XTIRType* fieldIRType = [self irTypeForASTTypeQuiet:ivarType];
            if (!fieldIRType)
                continue; // skip unsupported-type ivars
            NSUInteger fa = [XTStructType fieldAlignmentForType:ivarType];
            if (fa > instAlign)
                instAlign = fa;
            instOffset = (uint32_t)((instOffset + fa - 1) & ~(fa - 1));
            // A weak slot is preceded by two hidden link words; the recorded
            // field index points at the PAYLOAD, so every load/store is
            // unchanged. The links are pointer-pairs, so aligning the START
            // to the payload's alignment keeps links and payload contiguous
            // and both aligned. See appendWeakLinkFieldsTo:.
            if ([self astTypeIsWeakSlot:ivarType])
                {
                instOffset += [self appendWeakLinkFieldsTo:instanceFields
                                                  atOffset:instOffset
                                                fieldIndex:&fieldIndex];
                }
            [instanceFields addObject:[[XTIRLayoutField alloc] initWithOffset:instOffset
                                                                         type:fieldIRType]];
            info.ivarFieldIndex[ivar.varName] = @(fieldIndex++);
            info.ivarASTType[ivar.varName] = ivarType;
            instOffset += (uint32_t)ivarType.byteWidth;
            }
        }
    for (XTVariableDeclNode* ivar in cls.ivars)
        {
        // `static` ivar: one module global for the whole class, no instance
        // slot, no field index — see XTIRClassInfo.staticIvarSymbol.
        if (ivar.isStatic)
            {
            [self registerStaticIvar:ivar forClass:cls into:info];
            continue;
            }
        XTType* ivarType = ivar.declaredType ?: [XTType u8Type];
        XTIRType* fieldIRType = [self irTypeForASTTypeQuiet:ivarType];
        if (!fieldIRType)
            {
            // Tolerate-and-skip: an ivar with an unsupported type
            // (commonly float right now) keeps its slot in the
            // declared-name map so member-access codepaths produce a
            // recognisable "missing ivar" diagnostic later rather
            // than corrupting the layout, but we don't add the field
            // and don't bump the field counter — the slot effectively
            // disappears until float lowering lands.
            continue;
            }
        NSUInteger fa = [XTStructType fieldAlignmentForType:ivarType];
        if (fa > instAlign)
            instAlign = fa;
        instOffset = (uint32_t)((instOffset + fa - 1) & ~(fa - 1));
        // Weak slot: two hidden link words first — see appendWeakLinkFieldsTo:.
        if ([self astTypeIsWeakSlot:ivarType])
            {
            instOffset += [self appendWeakLinkFieldsTo:instanceFields
                                              atOffset:instOffset
                                            fieldIndex:&fieldIndex];
            }
        [instanceFields addObject:[[XTIRLayoutField alloc] initWithOffset:instOffset
                                                                     type:fieldIRType]];
        info.ivarFieldIndex[ivar.varName] = @(fieldIndex++);
        info.ivarASTType[ivar.varName] = ivarType;
        instOffset += (uint32_t)ivarType.byteWidth;
        }
    // Record the names this class declares (vs inherited), so the dealloc
    // teardown releases only OWN strong ivars and leaves the rest to the
    // super-chain.
    NSMutableSet<NSString*>* own = [NSMutableSet set];
    for (XTVariableDeclNode* ivar in cls.ivars)
        {
        if (ivar.isStatic)
            continue; // no instance slot, nothing to tear down
        [own addObject:ivar.varName];
        }
    info.ownIvarNames = own;
    // Tail-round the instance size to the class's alignment (max slot
    // alignment, capped) so `new T[N]` / `delete obj[]` stride correctly.
    // Cap 1 → instAlign 1 → no rounding, the historical layout.
    instOffset = (uint32_t)((instOffset + instAlign - 1) & ~(instAlign - 1));
    info.instanceLayout = [[XTIRLayout alloc] initWithSize:instOffset
                                                 alignment:1
                                                    fields:instanceFields];
    [self.module addLayout:info.instanceLayout];
    info.selfPtrType = [XTIRType ptrToType:[XTIRType aggWithLayout:info.instanceLayout]
                                    window:XTIRWindowUnbanked];
    // Register NOW, not at the end of the pre-scan: a type only ever needs
    // selfPtrType, and that exists the moment the layout does. Registering
    // late made the busy-guard fire for SIGNATURE lookups — the driver loop
    // starts class C, C's parent's signature loop drags in D on demand, and
    // D's own signatures mention C* while C is still mid-scan: C collapsed
    // to Ptr(Void) exactly the way task #20 was meant to stop (string_charset
    // caught it — String$byteIndexOfSet's CharacterSet* went Void). Only the
    // LAYOUT walk above still hides behind the busy set, because until here
    // there is no layout to hand out.
    self.classesByName[cls.className] = info;
    [self.preScanInProgress removeObject:cls.className];
    return info;
    }

// Phase 2 — everything that reads OTHER classes' signatures or the
// parent's phase-2 output. Parent-first, memoized.
- (void)preScanClassRest:(XTClassDeclNode*)cls info:(XTIRClassInfo*)info
    {
    if ([self.preScanRestDone containsObject:cls.className])
        return;
    [self.preScanRestDone addObject:cls.className];

    if (cls.parentClass)
        {
        [self preScanClassRest:cls.parentClass
                          info:[self preScanClassLayout:cls.parentClass]];
        }
    else if (cls.parentName)
        {
        XTClassDeclNode* parentDecl = self.classDeclsByName[cls.parentName];
        if (parentDecl)
            {
            [self preScanClassRest:parentDecl
                              info:[self preScanClassLayout:parentDecl]];
            }
        }
    XTIRClassInfo* parentInfo = info.parent;

    // -- VTable layout.
    //
    // Sema's computeVirtualMethodTables assigns the authoritative virtual /
    // protocol slot numbering (override-roots-then-protocol-methods), and
    // the call site dispatches through `resolvedVirtualSlot`. A dispatch
    // class MUST build its vtable from THAT numbering — stamped onto the
    // class node as vtableSlotSymbols / vtableMethodSlots — so vtable slot N
    // holds the impl that slot N dispatches to. (The old declaration-order
    // numbering disagreed: e.g. a protocol's `equals` landed at a different
    // slot than `resolvedVirtualSlot`, so dispatch hit the wrong body.)
    // Non-dispatch classes have no stamped table and emit no vtable, so they
    // keep the legacy declaration-order path.
    NSMutableArray<XTIRLayoutField*>* vtblFields = [NSMutableArray array];
    XTIRType* fnPtrType = [XTIRType ptrToType:[XTIRType voidType]
                                       window:XTIRWindowUnbanked];
    uint32_t vtblOffset = 0;
    // methodMangled (methodName→mangled) is independent of slot numbering.
    if (parentInfo)
        {
        [info.methodMangled addEntriesFromDictionary:parentInfo.methodMangled];
        }
    for (XTMethodDeclNode* m in cls.methods)
        {
        if (m.isStatic)
            continue;
        info.methodMangled[m.methodName] = m.mangledName ?: m.methodName;
        }

    // ── Itable (multi-module targets) ───────────────────────────────────────
    // One table per protocol this class conforms to, indexed by the method's
    // position in the PROTOCOL's own declaration — an index every module derives
    // identically, needing no agreement. The itable itself is (protoId, &table)
    // pairs terminated by a zero id, and it lives at vtable entry 0 so a dispatch
    // site can reach it from the receiver alone, in every class, at a fixed offset.
    NSString* itblName = nil;
    if ((sItableProtocols || sVtableConforms) && cls.protocolImplSymbols.count > 0)
        {
        NSMutableArray<NSString*>* pairs = [NSMutableArray array];
        for (NSString* pname in [cls.protocolImplSymbols.allKeys
                 sortedArrayUsingSelector:@selector(compare:)])
            {
            NSArray<NSString*>* row = cls.protocolImplSymbols[pname];
            NSString* tabName = [NSString stringWithFormat:@"%@$%@$itab", cls.className, pname];
            NSMutableArray<XTIRLayoutField*>* tf = [NSMutableArray array];
            uint32_t off = 0;
            for (NSUInteger i = 0; i < row.count; i++)
                {
                [tf addObject:[[XTIRLayoutField alloc] initWithOffset:off type:fnPtrType]];
                off += 2;
                }
            XTIRLayout* tlay = [[XTIRLayout alloc] initWithSize:off alignment:1 fields:tf];
            [self.module addLayout:tlay];
            XTIRSymbol* tsym = [XTIRSymbol vTableWithName:tabName layout:tlay];
            tsym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
            tsym.vtableEntryNames = row; // @"" = unimplemented optional -> null
            [self.module addSymbol:tsym];
            [pairs addObject:[NSString stringWithFormat:@"__protoid_%u", xtProtocolId(pname)]];
            [pairs addObject:tabName];
            }
        [pairs addObject:@"__protoid_0"]; // terminator
        [pairs addObject:@""];
        itblName = [NSString stringWithFormat:@"%@$itbl", cls.className];
        NSMutableArray<XTIRLayoutField*>* pf = [NSMutableArray array];
        uint32_t poff = 0;
        for (NSUInteger i = 0; i < pairs.count; i++)
            {
            [pf addObject:[[XTIRLayoutField alloc] initWithOffset:poff type:fnPtrType]];
            poff += 2;
            }
        XTIRLayout* play = [[XTIRLayout alloc] initWithSize:poff alignment:1 fields:pf];
        [self.module addLayout:play];
        XTIRSymbol* isym = [XTIRSymbol vTableWithName:itblName layout:play];
        isym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        isym.vtableEntryNames = pairs;
        [self.module addSymbol:isym];
        }

    // Ancestry link: vtable entry 0 is the PARENT class's vtable ("" → null, for a
    // root or a non-vtable parent). The `as?`/`as` downcast walks obj.vtbl → parent
    // → … at runtime, so a subclass defined in ANOTHER module — never in this
    // module's compile-time subtree — is still recognised as its base. It sits at a
    // FIXED offset 0 from the receiver's vtable pointer (before the itable), so every
    // vtable reads [parent][itable?][methods]; dispatch/vtbl-load add one word for it.
    NSString* parentVtbl = (info.parent && info.parent.needsVtable)
                               ? [NSString stringWithFormat:@"%@$vtbl", info.parent.className]
                               : @"";

    // ── Category chain (private:docs/Design/separate-compilation.md §4.2) ───────────
    // A category on a class that arrived from ANOTHER module cannot take a vtable
    // slot: that vtable is already emitted, inside someone else's image, and a
    // slot past its end is a read into whatever follows. Its methods live in a
    // side table instead — `<Class>$cat`, entry 0 a next-link (always null in this
    // pass; only the final link may extend an imported class) and entries 1.. the
    // methods by CHAIN slot, a numbering sema fixes per extended class.
    //
    // Emitted for the extended class AND for every class in this module that
    // descends from it, so an override reached through a base pointer lands on the
    // subclass's body. A receiver whose class this module never saw — a library's
    // own private subclass — has a NULL chain word and the dispatch site falls
    // back to the extended class's table, which is the right answer: nothing built
    // before the category existed can override it.
    NSString* catTblName = nil;
    NSArray<NSString*>* catSyms = cls.categoryChainSymbols;
    if (sVtableAncestry && catSyms.count > 0)
        {
        // §4.3b: the HOST's own table is the fallback and carries the anchor
        // name (`<Host>$cat$<names>`), distinct per extender at the linker; a
        // local subclass's table keeps `<Class>$cat` (the class name is
        // already unique). Entry [0] is the OWNER ANCHOR — the fallback's own
        // address, self-referential in the fallback itself — which dispatch
        // compares to tell this compilation's tables from another extender's.
        NSString* anchor = cls.categoryChainAnchor
                               ?: [NSString stringWithFormat:@"%@$cat", cls.categoryChainHost ?: cls.className];
        BOOL isHost = [cls.className isEqualToString:cls.categoryChainHost ?: cls.className];
        catTblName = isHost ? anchor
                            : [NSString stringWithFormat:@"%@$cat", cls.className];
        NSMutableArray<NSString*>* cents = [NSMutableArray arrayWithObject:anchor];
        [cents addObjectsFromArray:catSyms];
        NSMutableArray<XTIRLayoutField*>* cf = [NSMutableArray array];
        uint32_t coff = 0;
        for (NSUInteger i = 0; i < cents.count; i++)
            {
            [cf addObject:[[XTIRLayoutField alloc] initWithOffset:coff type:fnPtrType]];
            coff += 2;
            }
        XTIRLayout* clay = [[XTIRLayout alloc] initWithSize:coff alignment:1 fields:cf];
        [self.module addLayout:clay];
        XTIRSymbol* csym = [XTIRSymbol vTableWithName:catTblName layout:clay];
        csym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        csym.vtableEntryNames = cents;
        [self.module addSymbol:csym];
        info.catChainHost = cls.categoryChainHost ?: cls.className;
        info.catChainAnchor = anchor;
        info.catSlot = [(cls.categoryChainMethodSlots ?: @{}) mutableCopy];
        }

    NSArray<NSString*>* semaSlotSyms = cls.vtableSlotSymbols;
    if (info.needsVtable && semaSlotSyms.count > 0)
        {
        // Authoritative path: one vtable field per global slot; entries and
        // methodSlot come straight from sema (inheritance already resolved).
        NSMutableArray<NSString*>* ents = [semaSlotSyms mutableCopy];
        if (sItableProtocols || sVtableConforms)
            {
            // The itable pointer (null when the class conforms to nothing). Every
            // class reserves it, so a dispatch OR conformance-downcast site reaches
            // the itable at the SAME offset whatever the receiver's class or module.
            [ents insertObject:(itblName ?: @"") atIndex:0];
            }
        if (sVtableAncestry)
            {
            // The category-chain word, AFTER the itable so `_xtc_obj_conforms`'s
            // vtbl[1] is untouched. Reserved (null) in every vtable on these
            // targets: a client reading it off a library-built receiver must find
            // a chain word there, not that class's first method pointer.
            [ents insertObject:(catTblName ?: @"")
                       atIndex:((sItableProtocols || sVtableConforms) ? 1 : 0)];
            }
        info.vtableEntrySymbolNames = ents;
        info.methodSlot = [(cls.vtableMethodSlots ?: @{}) mutableCopy];
        for (NSUInteger i = 0; i < ents.count; i++)
            {
            [vtblFields addObject:[[XTIRLayoutField alloc] initWithOffset:vtblOffset
                                                                     type:fnPtrType]];
            vtblOffset += 2;
            }
        }
    else
        {
        // Legacy declaration-order path: inherit the parent's slot ordering
        // and append this class's new (non-overriding) methods.
        NSMutableArray<NSString*>* vtblEntries =
            parentInfo ? [parentInfo.vtableEntrySymbolNames mutableCopy]
                       : [NSMutableArray array];
        info.vtableEntrySymbolNames = vtblEntries;
        NSUInteger nextSlot = 0;
        if (parentInfo)
            {
            for (NSString* parentMethodName in parentInfo.methodSlot)
                {
                NSNumber* parentSlot = parentInfo.methodSlot[parentMethodName];
                info.methodSlot[parentMethodName] = parentSlot;
                if (parentSlot.unsignedIntegerValue + 1 > nextSlot)
                    {
                    nextSlot = parentSlot.unsignedIntegerValue + 1;
                    }
                }
            while (vtblFields.count < nextSlot)
                {
                [vtblFields addObject:[[XTIRLayoutField alloc] initWithOffset:vtblOffset
                                                                         type:fnPtrType]];
                vtblOffset += 2;
                }
            }
        for (XTMethodDeclNode* m in cls.methods)
            {
            if (m.isStatic)
                continue;
            NSString* mangled = m.mangledName ?: m.methodName;
            if (!info.methodSlot[m.methodName])
                {
                info.methodSlot[m.methodName] = @(nextSlot++);
                [vtblFields addObject:[[XTIRLayoutField alloc] initWithOffset:vtblOffset
                                                                         type:fnPtrType]];
                vtblOffset += 2;
                }
            NSUInteger slot = info.methodSlot[m.methodName].unsignedIntegerValue;
            NSString* entrySym = [NSString stringWithFormat:@"%@$%@", cls.className, mangled];
            while (vtblEntries.count <= slot)
                [vtblEntries addObject:@""];
            vtblEntries[slot] = entrySym;
            }
        }
    // Prepend the ancestry link at entry 0 — UNIFORMLY, after both slot paths, so
    // the sema path ([itable?][methods], relative methodSlot) and the legacy path
    // ([methods], absolute methodSlot) both end up [parent][…] and dispatch's single
    // universal +1 (below) lands every method correctly. methodSlot stays untouched;
    // the +1 accounts for this word. A root / non-vtable-parent link is "" → null,
    // which terminates the runtime walk.
    if (sVtableAncestry && info.needsVtable && info.vtableEntrySymbolNames)
        {
        NSMutableArray<NSString*>* withParent =
            [info.vtableEntrySymbolNames mutableCopy] ?: [NSMutableArray array];
        [withParent insertObject:parentVtbl atIndex:0];
        info.vtableEntrySymbolNames = withParent;
        [vtblFields addObject:[[XTIRLayoutField alloc] initWithOffset:vtblOffset type:fnPtrType]];
        vtblOffset += 2;
        }

    // Record each method's declared return type, parent-first so an
    // inherited-but-not-overridden method keeps the parent's signature. Both
    // slot paths above share this — the map is keyed by name, not by slot.
    if (parentInfo)
        [info.methodReturnAST addEntriesFromDictionary:parentInfo.methodReturnAST];
    for (XTMethodDeclNode* m in cls.methods)
        {
        if (m.isStatic)
            continue;
        XTType* ret = m.returnTypes.firstObject;
        if (ret)
            info.methodReturnAST[m.methodName] = ret;
        }

    info.vtableLayout = [[XTIRLayout alloc] initWithSize:vtblOffset
                                               alignment:1
                                                  fields:vtblFields];
    [self.module addLayout:info.vtableLayout];

    // -- VTable symbol.
    // Only classes that participate in dispatch get a VTable symbol
    // emitted (and a `new`-time vtable-pointer store). Non-dispatch
    // classes skip it — they'd otherwise bloat code+data for nothing
    // (and large fixtures hit the screen-RAM guard). The entry list is
    // still built above so a dispatch subclass can inherit a non-vtable
    // parent's method symbols.
    if (info.needsVtable)
        {
        NSString* vtblName = [NSString stringWithFormat:@"%@$vtbl", cls.className];
        XTIRSymbol* vtblSym = [XTIRSymbol vTableWithName:vtblName layout:info.vtableLayout];
        // W2: an imported class's symbols resolve from its library's package
        // (wasm32) — the pkg_<X> attribute rides the generic machinery.
        if (cls.isExternal && cls.importPackage.length)
            vtblSym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, [@"pkg_" stringByAppendingString:cls.importPackage] : @YES};
        else
            vtblSym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
        vtblSym.vtableEntryNames = info.vtableEntrySymbolNames;
        // An imported class's vtable is DEFINED IN ITS LIBRARY. Emitting a local copy
        // here would give this module a SECOND vtable at a different address — and the
        // RTTI downcast compares vtable ADDRESSES (the instance's slot-0 vs
        // AddrOf(<Class>$vtbl)), so a library-created object would never match the
        // client's local copy and `(T@ ?)` would return null. Mark it `extern` so the
        // backend emits only a reference and the loader resolves every module to the
        // one exported table. (Methods already extern via `!m.body && !cls.isExternal`.)
        if (cls.isExternal)
            vtblSym.isExternalGlobal = YES;
        info.vtableSymbolId = [self.module addSymbol:vtblSym];
        }

    // (Registered in classesByName just after the instance layout above —
    // early, so a signature met during another class's pre-scan resolves.)

    // -- Method skeletons: one XTIRFunction per method body. Hidden
    // `self` is the first formal for instance methods. For an imported class
    // (--emit-lib binary module) the methods are body-less externs — register
    // the Class$method symbol anyway so call sites resolve and the backend emits
    // a `bl` to the .so; lowerClass: still skips emitting a (nonexistent) body.
    for (XTMethodDeclNode* m in cls.methods)
        {
        if (!m.body && !cls.isExternal)
            continue;
        if (m.returnTypes.count > 1)
            {
            // Multi-return method: register with aggregate return type.
            XTIRLayout* tupleLayout = [self layoutForTupleReturnTypes:m.returnTypes];
            if (!tupleLayout)
                continue;
            XTIRType* irRet = [XTIRType aggWithLayout:tupleLayout];

            NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
            if (!m.isStatic)
                {
                [paramTypes addObject:info.selfPtrType];
                }
            BOOL signatureOK = YES;
            for (XTParamNode* p in m.parameters)
                {
                XTIRType* t = [self irTypeForASTTypeQuiet:p.paramType];
                if (!t)
                    {
                    signatureOK = NO;
                    break;
                    }
                [paramTypes addObject:t];
                }
            if (!signatureOK)
                continue;
            [paramTypes addObject:[XTIRType memoryType]];

            NSString* mangled = m.mangledName ?: m.methodName;
            NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                           cls.className, mangled];
            if ([self.module symbolForName:symName])
                continue;

            XTIRBlock* entry = [[XTIRBlock alloc] init];
            entry.name = @"bb_entry";
            XTIRFunction* fn = [[XTIRFunction alloc] initWithName:symName
                                                       returnType:irRet
                                                       paramTypes:paramTypes
                                                       entryBlock:entry];
            XTIRSymbol* sym = [XTIRSymbol functionWithName:symName function:fn type:nil];
            if (cls.isExternal && cls.importPackage.length)
                sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO, [@"pkg_" stringByAppendingString:cls.importPackage] : @YES};
            else
                sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
            [self.module addSymbol:sym];
            continue;
            }
        XTType* astRet = m.returnTypes.firstObject ?: [XTType voidType];
        XTIRType* irRet = [self irTypeForASTTypeQuiet:astRet];
        if (!irRet)
            continue; // skip-on-unsupported

        NSMutableArray<XTIRType*>* paramTypes = [NSMutableArray array];
        if (!m.isStatic)
            {
            [paramTypes addObject:info.selfPtrType];
            }
        BOOL signatureOK = YES;
        for (XTParamNode* p in m.parameters)
            {
            XTIRType* t = [self irTypeForASTTypeQuiet:p.paramType];
            if (!t)
                {
                signatureOK = NO;
                break;
                }
            [paramTypes addObject:t];
            }
        if (!signatureOK)
            continue;
        [paramTypes addObject:[XTIRType memoryType]];

        NSString* mangled = m.mangledName ?: m.methodName;
        NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                       cls.className, mangled];
        if ([self.module symbolForName:symName])
            continue;

        XTIRBlock* entry = [[XTIRBlock alloc] init];
        entry.name = @"bb_entry";
        XTIRFunction* fn = [[XTIRFunction alloc] initWithName:symName
                                                   returnType:irRet
                                                   paramTypes:paramTypes
                                                   entryBlock:entry];
        XTIRSymbol* sym = [XTIRSymbol functionWithName:symName function:fn type:nil];
        BOOL cloaked = (m.placement == XTPlacementCloaked);
        BOOL banked = (m.placement == XTPlacementBanked);
        // `throws` must reach the SYMBOL: emitCall reads it to decide whether a
        // call site needs an error check. Without it a method could throw but no
        // caller would ever test the channel, leaving the handler unreachable.
        // Added only when SET, matching the free-function path — emitting
        // `throws: false` on every method would churn every golden IR file.
        NSMutableDictionary* mattrs = [@{@"cloaked" : @(cloaked),
                                         @"banked" : @(banked),
                                         @"variadic" : @(m.isVarArgs),
                                         @"static" : @(m.isStatic)} mutableCopy];
        if (m.throwsError)
            mattrs[@"throws"] = @YES;
        if (m.forwardsVarargs)
            mattrs[@"vaforward"] = @YES;
        // W2: an imported class's method shells import from the library's
        // package on wasm32 (same pkg_<X> key the #package plumbing uses).
        if (cls.isExternal && cls.importPackage.length)
            mattrs[[@"pkg_" stringByAppendingString:cls.importPackage]] = @YES;
        sym.attributes = mattrs;
        [self.module addSymbol:sym];
        }

    // Synthesise a `<Class>$dealloc` for a class that owns strong
    // class-pointer ivars but declared no dealloc: releasing an instance
    // at scope exit must run the strong-ivar teardown, which only fires
    // inside a $dealloc. lowerClass emits its (empty) body — the void
    // return then drives releaseStrongIvarsForDeallocTeardown. Without
    // this, `new T(); ...` where T has a strong field leaks the field.
    XTMethodDeclNode* userDealloc = nil;
    for (XTMethodDeclNode* m in cls.methods)
        {
        if ([m.methodName isEqualToString:@"dealloc"])
            {
            userDealloc = m;
            break;
            }
        }
    if (userDealloc)
        {
        // Record whether the body already chains to super, so the teardown
        // doesn't auto-append a second super.dealloc() (Dog.dealloc).
        if ([self astCallsSuperDealloc:userDealloc.body])
            {
            if (!self.deallocCallsSuper)
                self.deallocCallsSuper = [NSMutableSet set];
            [self.deallocCallsSuper addObject:cls.className];
            }
        }
    else
        {
        BOOL hasStrongOwnIvar = NO;
        for (XTVariableDeclNode* ivar in cls.ivars)
            {
            if (ivar.isStatic)
                continue; // class-level storage outlives instances
            if ([self astTypeIsClassPointer:ivar.declaredType])
                {
                hasStrongOwnIvar = YES;
                break;
                }
            // An auto-zeroing ivar — `weak:T@` or a bound method `^` — owns
            // nothing, but it IS linked into its referent's chain, and that link
            // must be dropped when the holder dies. Without a $dealloc there is
            // nowhere for that to happen, so a class whose only ARC-relevant
            // ivar is one of these needs one synthesised just as much as a class
            // holding a strong reference does. (It previously got none, which is
            // what left the dangling chain entry above.)
            if ([self astTypeIsWeakClassPointer:ivar.declaredType] || ivar.declaredType.boundMethodSignature != nil)
                {
                hasStrongOwnIvar = YES;
                break;
                }
            }
        // Synthesise a <Class>$dealloc when the class owns a strong ivar
        // (release it — phase-145) OR an ancestor has a dealloc, so a freed
        // instance still runs the inherited teardown via the super-chain
        // (parent pre-scanned first, so its $dealloc symbol already exists).
        BOOL ancestorHasDealloc = NO;
        for (XTIRClassInfo* p = info.parent; p != nil; p = p.parent)
            {
            if ([self.module symbolForName:[NSString stringWithFormat:@"%@$dealloc", p.className]])
                {
                ancestorHasDealloc = YES;
                break;
                }
            }
        NSString* deallocSym = [NSString stringWithFormat:@"%@$dealloc", cls.className];
        if ((hasStrongOwnIvar || ancestorHasDealloc) && ![self.module symbolForName:deallocSym])
            {
            XTIRBlock* dentry = [[XTIRBlock alloc] init];
            dentry.name = @"bb_entry";
            XTIRFunction* dfn = [[XTIRFunction alloc]
                initWithName:deallocSym
                  returnType:[self irTypeForASTTypeQuiet:[XTType voidType]]
                  paramTypes:@[ info.selfPtrType, [XTIRType memoryType] ]
                  entryBlock:dentry];
            XTIRSymbol* dsym = [XTIRSymbol functionWithName:deallocSym function:dfn type:nil];
            dsym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
            [self.module addSymbol:dsym];
            if (!self.synthDeallocClasses)
                self.synthDeallocClasses = [NSMutableSet set];
            [self.synthDeallocClasses addObject:cls.className];
            }
        }
    }

// Lazily create (and cache) the `__sdata_<Class>` static-storage
// block: a zeroed DataGlobal sized to the class's instance layout.
// A static method's `self` is this block's address, so the ordinary
// ivar FieldAddr machinery reaches the fields. Returns its symbol-id.
- (XTIRSymbolId)staticDataSymbolForClass:(XTIRClassInfo*)info
    {
    NSNumber* cached = self.staticDataByClass[info.className];
    if (cached)
        return cached.unsignedIntegerValue;
    NSString* name = [NSString stringWithFormat:@"__sdata_%@", info.className];
    XTIRType* aggTy = [XTIRType aggWithLayout:info.instanceLayout];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:name
                                                type:aggTy
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    XTIRSymbolId sid = [self.module addSymbol:sym];
    self.staticDataByClass[info.className] = @(sid);
    return sid;
    }

// Lazily create (and cache) the `__sinit_<Class>` once-guard flag: a
// zeroed u8 DataGlobal. Returns its symbol-id.
- (XTIRSymbolId)staticInitFlagSymbolForClass:(XTIRClassInfo*)info
    {
    NSNumber* cached = self.staticInitFlagByClass[info.className];
    if (cached)
        return cached.unsignedIntegerValue;
    NSString* name = [NSString stringWithFormat:@"__sinit_%@", info.className];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:name
                                                type:[XTIRType u8Type]
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    XTIRSymbolId sid = [self.module addSymbol:sym];
    self.staticInitFlagByClass[info.className] = @(sid);
    return sid;
    }

// Before a static method call (`Stdio.printf(...)`), emit a once-per-run
// guard that runs the class's `init` on the `__sdata` block:
//
//   if (__sinit_<C> == 0) { __sinit_<C> = 1; <C>$init(&__sdata_<C>); }
//
// The static method body reaches its fields through `&__sdata`, so `init`
// (a normal method taking `self`) is invoked with that same address. A
// class with no `init` (walking parents) needs no guard. Splits the
// current block: pred -CondBranch-> {initBB, contBB}; initBB -> contBB.
// The guard defines no live-out locals, so contBB needs no phis.
- (void)emitStaticInitGuardForClass:(XTIRClassInfo*)recvCi
    {
    // …but only for a class that is never instantiated. Running an INSTANCE
    // initialiser against the class's static block is the static-class idiom
    // (Stdio, Assert: no `new`, ivars are class state, `init` sets them up).
    // For a class that is also `new`ed it is a category error, and a visible
    // one now that `static` ivars exist:
    //
    //     class Counter { static u16 made;  void init(void) { made = made+1; } }
    //     Counter.cap();          // ← used to run init on __sdata: made == 1
    //     Counter@ a = new Counter();
    //     Counter.total();        // ← 2, after ONE instance
    //
    // sema's usedByNew (propagated up the parent chain) is the distinction.
    //
    // Narrowed to classes that actually DECLARE a static ivar. The general
    // case — an instantiated class with no static ivar — keeps the phantom
    // init, deliberately: dropping the guard there removes calls from the
    // graph and reshuffles the xt6502 bank packer, which pushed
    // foundation_map_insertion_order ten bytes past the end of the unbanked
    // region. That is a packing-margin problem, not a correctness one, and it
    // is not worth spending on a case no program can currently observe (with
    // no static ivar there is no shared name to see the phantom's writes).
    if (recvCi.usedByNew)
        {
        for (XTIRClassInfo* c = recvCi; c != nil; c = c.parent)
            if (c.staticIvarSymbol.count > 0)
                return;
        }
    // Resolve `init` (own or inherited); nothing to do without one.
    XTIRSymbol* isym = nil;
    XTIRClassInfo* owner = nil;
    for (XTIRClassInfo* c = recvCi; c != nil; c = c.parent)
        {
        NSString* s = [NSString stringWithFormat:@"%@$init", c.className];
        XTIRSymbol* cand = [self.module symbolForName:s];
        if (cand && cand.function)
            {
            isym = cand;
            owner = c;
            break;
            }
        }
    if (!isym)
        return;
    XTIRSymbolId iid = [self.module.symbols indexOfObjectIdenticalTo:isym];

    XTIRSymbolId flagSid = [self staticInitFlagSymbolForClass:recvCi];
    XTIRSymbolId sdataSid = [self staticDataSymbolForClass:recvCi];
    XTIRType* u8t = [XTIRType u8Type];
    XTIRType* u8Ptr = [XTIRType ptrToType:u8t window:XTIRWindowUnbanked];

    // Single-threaded (the default): flagVal == 0 means "not yet run".
    // Threaded: the flag is tri-state and DONE is 2, so the fast path tests
    // `!= 2` — the same load / compare / branch, one immediate different.
    // 0 = untouched, 1 = an init is in flight, 2 = complete.
    BOOL safeOnce = self.threadSafeStatics;
    int doneVal = safeOnce ? 2 : 0;

    // flagPtr = &__sinit_<C>; flagVal = *flagPtr; cond = (flagVal <cmp> doneVal)
    XTIRValue* flagPtr = [self emitInsnOpcode:XTIROpAddrOf
                                       result:u8Ptr
                                     operands:@[ [XTIROperand symWithSymbolId:flagSid] ]];
    XTIRValue* flagVal = [self emitLoad:flagPtr pointeeType:u8t];
    XTIRValue* zero = [self allocateValueOfType:u8t atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                     result:zero
                                                   operands:@[ [XTIROperand immIWithType:u8t value:doneVal] ]
                                                     dbgLoc:nil]];
    XTIRValue* cond = [self allocateValueOfType:[XTIRType boolType] atSite:self.currentBlock];
    [self.currentBlock appendInstruction:
                           [[XTIRInsn alloc] initWithOpcode:XTIROpICmp
                                                     result:cond
                                                   operands:@[ [XTIROperand useWithValueId:flagVal.valueId],
                                                               [XTIROperand useWithValueId:zero.valueId] ]
                                                  predicate:(safeOnce ? XTIRICmpNE : XTIRICmpEQ)dbgLoc:nil]];

    NSString* prefix = [NSString stringWithFormat:@"bb_%lu_sinit_%@",
                                                  (unsigned long)self.currentFunction.blocks.count, recvCi.className];
    XTIRBlock* initBB = [self addBlockWithName:[prefix stringByAppendingString:@"_run"]];
    XTIRBlock* contBB = [self addBlockWithName:[prefix stringByAppendingString:@"_cont"]];
    [self emitTerminator:XTIROpCondBranch
                operands:@[ [XTIROperand useWithValueId:cond.valueId],
                            [XTIROperand blockWithRef:initBB],
                            [XTIROperand blockWithRef:contBB] ]];

    // initBB: single-threaded — `__sinit_<C> = 1` then run init. The flag is set
    // BEFORE the body so a re-entrant static use of the SAME class sees zeroed
    // state instead of recursing (static_init_once.xc pins that).
    //
    // Threaded — the whole body becomes ONE call to `_xtc_sinit_run`, which does
    // the 0→1 claim atomically, runs the initialiser if it won, and publishes 2.
    // A re-entrant caller on the owning thread returns immediately and sees the
    // same zeroed state as before; a DIFFERENT thread blocks until 2 is
    // published. That last case is the half of the bug a bare CAS would leave:
    // without the wait, the loser proceeds on statics still being written.
    self.currentBlock = initBB;
    if (safeOnce)
        {
        /* One call, then the branch to cont — deliberately a SINGLE block.
         * `_xtc_sinit_run` takes the initialiser and its static block and does
         * the claim, the call and the publish itself, so no branch is needed
         * between them. An earlier version split it (enter -> test -> call ->
         * done) and that cost the optimisation: XTIROptStaticInitGuard requires
         * a run block that is one block ending in Branch, so threaded programs
         * silently kept an un-hoisted guard. */
        XTIRSymbolId runSid = [self runtimeHelperSymbolNamed:@"_xtc_sinit_run"];
        XTIRValue* initPtr = [self emitInsnOpcode:XTIROpAddrOf
                                           result:u8Ptr
                                         operands:@[ [XTIROperand symWithSymbolId:iid] ]];
        XTIRValue* sdataArg = [self emitInsnOpcode:XTIROpAddrOf
                                            result:recvCi.selfPtrType
                                          operands:@[ [XTIROperand symWithSymbolId:sdataSid] ]];
        (void)[self emitCall:runSid
                    callConv:[XTIRCallConv standard]
                   argValues:@[ flagPtr, initPtr, sdataArg ]
                  resultType:nil];
        [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:contBB] ]];
        self.currentBlock = contBB;
        return;
        }
        {
        XTIRValue* one = [self allocateValueOfType:u8t atSite:self.currentBlock];
        [self.currentBlock appendInstruction:
                               [[XTIRInsn alloc] initWithOpcode:XTIROpConst
                                                         result:one
                                                       operands:@[ [XTIROperand immIWithType:u8t value:1] ]
                                                         dbgLoc:nil]];
        [self emitStore:flagPtr value:one];
        }
    XTIRValue* sdataPtr = [self emitInsnOpcode:XTIROpAddrOf
                                        result:recvCi.selfPtrType
                                      operands:@[ [XTIROperand symWithSymbolId:sdataSid] ]];
    XTIRCallConv* conv =
        isym.attributes[@"cloaked"].boolValue  ? [XTIRCallConv cloaked]
        : isym.attributes[@"banked"].boolValue ? [XTIRCallConv banked]
                                               : [XTIRCallConv standard];
    (void)owner;
    (void)[self emitCall:iid callConv:conv argValues:@[ sdataPtr ] resultType:nil];
    [self emitTerminator:XTIROpBranch operands:@[ [XTIROperand blockWithRef:contBB] ]];

    self.currentBlock = contBB;
    }

// Find the symbol name of the nearest ancestor's NO-ARG `init` for an
// auto-`super.init()` injection — mirrors sema's wireSubclassInitChains
// search. Walks parents; stops at the first ancestor that declares any
// init (a no-arg one is the target, otherwise there's nothing to chain
// to). Returns nil if no chainable no-arg init exists.
- (nullable NSString*)parentNoArgInitSymbolFor:(XTClassDeclNode*)cls
    {
    for (XTClassDeclNode* p = cls.parentClass; p != nil; p = p.parentClass)
        {
        XTMethodDeclNode* noArg = nil;
        BOOL anyInit = NO;
        for (XTMethodDeclNode* pm in p.methods)
            {
            if (![pm.methodName isEqualToString:@"init"])
                continue;
            anyInit = YES;
            if (pm.parameters.count == 0)
                {
                noArg = pm;
                break;
                }
            }
        if (noArg)
            {
            NSString* mangled = noArg.mangledName ?: noArg.methodName;
            return [NSString stringWithFormat:@"%@$%@", p.className, mangled];
            }
        if (anyInit)
            break;
        }
    return nil;
    }

/****************************************************************************\
|* Give a `static` ivar its module global. One per class per name, zeroed
|* unless the declaration carries a constant-foldable initialiser — the same
|* deal a function-local `static` gets, and for the same reason: the value
|* must survive between calls and the initialiser must run once, at load
|* time, rather than on every entry.
\****************************************************************************/
- (void)registerStaticIvar:(XTVariableDeclNode*)ivar
                  forClass:(XTClassDeclNode*)cls
                      into:(XTIRClassInfo*)info
    {
    XTType* astTy = ivar.declaredType ?: [XTType u8Type];
    XTIRType* irTy = [self irTypeForASTTypeQuiet:astTy];
    if (!irTy)
        return; // unsupported type — as elsewhere
    NSString* name = [NSString stringWithFormat:@"__sivar_%@_%@",
                                                cls.className, ivar.varName];
    XTIRSymbol* sym = [XTIRSymbol dataGlobalWithName:name
                                                type:irTy
                                            volatile:NO
                                             escapes:YES
                                           taskLocal:NO];
    sym.attributes = @{@"cloaked" : @NO, @"banked" : @NO};
    if (ivar.initialiser)
        {
        NSData* bytes = [self tryFoldInitialiser:ivar.initialiser toType:astTy];
        if (bytes)
            sym.initialBytes = bytes;
        else
            [self.diag emitNote:[NSString stringWithFormat:
                                              @"lowering: static ivar '%@.%@' initialiser is not constant — "
                                              @"slot zero-initialised",
                                              cls.className, ivar.varName]
                             at:ivar.location ?: cls.location];
        }
    info.staticIvarSymbol[ivar.varName] = @([self.module addSymbol:sym]);
    info.ivarASTType[ivar.varName] = astTy; // for type queries; no field index
    }

/****************************************************************************\
|* Bind every static ivar visible to `info` — its own and its ancestors' —
|* into globalsByName, so an unqualified read or write inside a method body
|* takes the ordinary global path (AddrOf + Load/Store). Returns the previous
|* bindings so the caller can restore them; NSNull marks "was unbound".
|*
|* Done per CLASS rather than per method because the binding is the same for
|* every method of the class, static or not — which is the whole point.
\****************************************************************************/
- (NSDictionary<NSString*, id>*)bindStaticIvarsForClass:(XTIRClassInfo*)info
    {
    NSMutableDictionary<NSString*, id>* saved = [NSMutableDictionary dictionary];
    // Root-first, so a nearer class wins if two levels declare the same name.
    NSMutableArray<XTIRClassInfo*>* chain = [NSMutableArray array];
    for (XTIRClassInfo* c = info; c != nil; c = c.parent)
        [chain insertObject:c atIndex:0];
    for (XTIRClassInfo* c in chain)
        {
        [c.staticIvarSymbol enumerateKeysAndObjectsUsingBlock:
                                ^(NSString* name, NSNumber* sid, BOOL* stop) {
                                  if (!saved[name])
                                      saved[name] = self.globalsByName[name] ?: [NSNull null];
                                  self.globalsByName[name] = sid;
                                }];
        }
    return saved;
    }

- (void)restoreGlobalBindings:(NSDictionary<NSString*, id>*)saved
    {
    [saved enumerateKeysAndObjectsUsingBlock:^(NSString* name, id prev, BOOL* stop) {
      if ([prev isKindOfClass:[NSNull class]])
          [self.globalsByName removeObjectForKey:name];
      else
          self.globalsByName[name] = prev;
    }];
    }

- (void)lowerClass:(XTClassDeclNode*)cls
    {
    XTIRClassInfo* info = self.classesByName[cls.className];
    if (!info)
        return;
    self.currentClassInfo = info;
    NSDictionary<NSString*, id>* savedGlobals = [self bindStaticIvarsForClass:info];
    for (XTMethodDeclNode* m in cls.methods)
        {
        if (!m.body)
            continue;
        // Auto-`super.init()`: sema set m.autoSuperInit when this init omits
        // an explicit super call and an ancestor has a no-arg init. Record
        // the parent target so _lowerCallable injects the call at the top
        // of the body. Cleared for every other method.
        self.pendingAutoSuperInitTarget =
            (m.autoSuperInit && !m.isStatic && [m.methodName isEqualToString:@"init"])
                ? [self parentNoArgInitSymbolFor:cls]
                : nil;
        if (m.returnTypes.count > 1)
            {
            // Multi-return method body lowering — the symbol was
            // registered during pre-scan with an aggregate return type.
            NSString* mangled = m.mangledName ?: m.methodName;
            NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                           cls.className, mangled];
            XTIRSymbol* sym = [self.module symbolForName:symName];
            XTIRFunction* fn = sym.function;
            if (!fn)
                continue;

            NSMutableArray<NSString*>* paramNames = [NSMutableArray array];
            if (!m.isStatic)
                [paramNames addObject:@"self"];
            for (XTParamNode* p in m.parameters)
                {
                [paramNames addObject:p.paramName];
                }
            self.staticSelfClassName = m.isStatic ? cls.className : nil;
            self.pendingRetainSelf = m.hasHeapReceiver && !m.hasNonHeapReceiver && !m.isStatic;
            self.currentFnThrows = m.throwsError;
            [self _lowerCallable:fn
                      paramNames:paramNames
                            body:m.body
                    preBoundSelf:m.isStatic ? nil : @"self"];
            self.staticSelfClassName = nil;
            continue;
            }
        NSString* mangled = m.mangledName ?: m.methodName;
        NSString* symName = [NSString stringWithFormat:@"%@$%@",
                                                       cls.className, mangled];
        XTIRSymbol* sym = [self.module symbolForName:symName];
        XTIRFunction* fn = sym.function;
        if (!fn)
            continue;

        NSMutableArray<NSString*>* paramNames = [NSMutableArray array];
        if (!m.isStatic)
            [paramNames addObject:@"self"];
        for (XTParamNode* p in m.parameters)
            {
            [paramNames addObject:p.paramName];
            }
        // Static methods have no `self` param; their `self` is the
        // address of the class's `__sdata` block, synthesized at
        // function entry by _lowerCallable when staticSelfClassName
        // is set.
        self.staticSelfClassName = m.isStatic ? cls.className : nil;
        self.pendingRetainSelf = m.hasHeapReceiver && !m.hasNonHeapReceiver && !m.isStatic;
        self.currentFnThrows = m.throwsError;
        [self _lowerCallable:fn
                  paramNames:paramNames
                        body:m.body
                preBoundSelf:m.isStatic ? nil : @"self"];
        self.staticSelfClassName = nil;
        }
    // Emit the body of a synthesised `<Class>$dealloc` (registered in
    // preScanClass for a strong-ivar class with no user dealloc). The
    // empty body lowers to the void-return path, which runs the strong-
    // ivar teardown via releaseStrongLocalsAlongReturnExcept:.
    if ([self.synthDeallocClasses containsObject:cls.className])
        {
        NSString* deallocSym = [NSString stringWithFormat:@"%@$dealloc", cls.className];
        XTIRSymbol* dsym = [self.module symbolForName:deallocSym];
        if (dsym.function && dsym.function.entryBlock.instructions.count == 0)
            {
            XTBlockNode* emptyBody = [[XTBlockNode alloc] initWithStatements:@[]
                                                                    location:cls.location];
            self.staticSelfClassName = nil;
            self.pendingRetainSelf = NO;
            [self _lowerCallable:dsym.function
                      paramNames:@[ @"self" ]
                            body:emptyBody
                    preBoundSelf:@"self"];
            }
        }
    [self restoreGlobalBindings:savedGlobals];
    self.currentClassInfo = nil;
    }

#pragma mark - ARC returnsRetained pre-scan (task #123)

// Collect the single-value `return` expressions reachable in a body.
// Sets *sawBad if a return is void/multi-value (a class-pointer fn with
// such a return can hand back garbage on that path, so it must NOT be
// classified +1). Missing node kinds are simply not descended into —
// conservative (their returns go uncounted → fn stays +0).
- (void)collectReturnExprsIn:(nullable XTASTNode*)node
                        into:(NSMutableArray<XTASTNode*>*)out
                      sawBad:(BOOL*)sawBad
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            [self collectReturnExprsIn:s into:out sawBad:sawBad];
        break;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectReturnExprsIn:n.thenBlock into:out sawBad:sawBad];
        [self collectReturnExprsIn:n.elseBlock into:out sawBad:sawBad];
        break;
        }
    case XTASTNodeKindWhile:
        [self collectReturnExprsIn:((XTWhileNode*)node).body into:out sawBad:sawBad];
        break;
    case XTASTNodeKindForCStyle:
        [self collectReturnExprsIn:((XTForCStyleNode*)node).body into:out sawBad:sawBad];
        break;
    case XTASTNodeKindForIn:
        [self collectReturnExprsIn:((XTForInNode*)node).body into:out sawBad:sawBad];
        break;
    case XTASTNodeKindReturn:
        {
        XTReturnNode* r = (XTReturnNode*)node;
        if (r.values.count == 1)
            [out addObject:r.values.firstObject];
        else
            *sawBad = YES; // void/multi return in a +1 candidate
        break;
        }
    default:
        break;
        }
    }

// Collect names of class-pointer (strong) local var-decls in a body.
- (void)collectStrongLocalNamesIn:(nullable XTASTNode*)node
                             into:(NSMutableSet<NSString*>*)out
    {
    if (!node)
        return;
    switch (node.nodeKind)
        {
    case XTASTNodeKindBlock:
        for (XTASTNode* s in ((XTBlockNode*)node).statements)
            [self collectStrongLocalNamesIn:s into:out];
        break;
    case XTASTNodeKindIf:
        {
        XTIfNode* n = (XTIfNode*)node;
        [self collectStrongLocalNamesIn:n.thenBlock into:out];
        [self collectStrongLocalNamesIn:n.elseBlock into:out];
        break;
        }
    case XTASTNodeKindWhile:
        [self collectStrongLocalNamesIn:((XTWhileNode*)node).body into:out];
        break;
    case XTASTNodeKindForCStyle:
        {
        XTForCStyleNode* f = (XTForCStyleNode*)node;
        [self collectStrongLocalNamesIn:f.loopInit into:out];
        [self collectStrongLocalNamesIn:f.body into:out];
        break;
        }
    case XTASTNodeKindForIn:
        [self collectStrongLocalNamesIn:((XTForInNode*)node).body into:out];
        break;
    case XTASTNodeKindVariableDecl:
        {
        XTVariableDeclNode* vd = (XTVariableDeclNode*)node;
        if ([self astTypeIsClassPointer:vd.declaredType])
            [out addObject:vd.varName];
        break;
        }
    default:
        break;
        }
    }

// THE ARC RETURN CONVENTION, in one place.
//
// Every call that yields a class pointer yields it at +1. The caller adopts —
// it registers the result as an owned temp, so a strong binding takes ownership
// and an unused result is released by the end-of-full-expression sweep. The
// callee retains a borrowed return value before its own teardown runs.
//
// It used to be conditional: +1 only when a whole-program fixpoint could prove
// EVERY return in the body was already owned, +0 otherwise, with the caller
// retaining. Two things were wrong with that.
//
// It is unsound when the callee's teardown owns the value. `return (T@)
// list.get(0);` hands back a reference the local list owns, the list is
// released on the way out, and the caller retains freed memory. No fixture
// covered it; selfhost/parser/Parser.xc hit it on its first run.
//
// And it cannot cross a module boundary. The classification is derived from
// the BODY, per compilation unit, and is not carried in the interface — so a
// factory returning `new T` is +1 inside its library and +0 to an importer that
// has never seen it, and every returned object leaks. Measured, before this
// change: ten calls, ten objects still alive (tests/crossmod/native-arm64.sh);
// the identical source in one module leaked nothing.
//
// A uniform rule needs no analysis, cannot disagree across a boundary, and
// cannot change an ABI when someone edits a body. The cost is a retain/release
// pair on accessors that used to hand back +0 — visible on xt6502, where both
// are JSRs, and the redundant-retain peephole already elides the alias case.
// Is `v` the current binding of a strong local? Such a value is EXEMPTED from
// the return teardown (its +1 moves to the caller), so retaining it again would
// leak. Mirrors the exemption releaseStrongLocalsAlongReturnExcept: applies.
- (BOOL)returnValueIsExemptStrongLocal:(XTIRValue*)v
    {
    // Follow Bitcasts back to their source, exactly as the teardown's exemption
    // does (#808). `return (Object@)t;` returns a CAST of the strong local `t`,
    // and the teardown already declines to release `t` on that path — so a
    // retain here would be the second +1 on a value with one release, and the
    // object would never die.
    for (XTIRValue* cur = v; cur; cur = self.bitcastSource[@(cur.valueId)])
        {
        for (NSMutableArray<NSString*>* frame in self.arcScopeStack)
            {
            for (NSString* name in frame)
                {
                XTIRValue* lv = self.locals[name];
                if (lv && lv.valueId == cur.valueId)
                    return YES;
                }
            }
        }
    return NO;
    }

- (BOOL)astCallYieldsOwnedClassPointer:(XTASTNode*)callNode
    {
    return [self astTypeIsClassPointer:callNode.resolvedType];
    }

// The AST type alone is not enough to decide that a value is retainable.
// `return get(key) != (Object@)0;` is a COMPARISON, but sema leaves the
// class-pointer type on the binary node, so the AST check says "class pointer"
// for a value the lowering produced as a Bool. Retaining that reads a refcount
// two bytes below a boolean and takes the whole program out — this is what
// crashed foundation_map_basic. Every ownership decision that ends in a
// Retain/Release therefore also asks the IR value what it actually is.
- (BOOL)irValueIsPointer:(nullable XTIRValue*)v
    {
    return v && v.type && v.type.kind == XTIRTypeKindPtr;
    }

#pragma mark - Public entry

+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag
    {
    return [self lowerProgram:program moduleName:name diagnostics:diag nativeVarargs:NO];
    }

+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag
                       nativeVarargs:(BOOL)nativeVarargs
    {
    return [self lowerProgram:program
                   moduleName:name
                  diagnostics:diag
                nativeVarargs:nativeVarargs
                  boundsCheck:NO];
    }

+ (nullable XTIRModule*)lowerProgram:(XTProgramNode*)program
                          moduleName:(NSString*)name
                         diagnostics:(XTDiagnosticEngine*)diag
                       nativeVarargs:(BOOL)nativeVarargs
                         boundsCheck:(BOOL)boundsCheck
    {
    XTIRLowering* L = [[XTIRLowering alloc] init];
    L.module = [[XTIRModule alloc] initWithName:name];
    L.diag = diag;
    L.nativeVarargs = nativeVarargs;
    L.boundsCheck = boundsCheck;
    L.classesByName = [NSMutableDictionary dictionary];
    L.classDeclsByName = [NSMutableDictionary dictionary];
    L.preScanInProgress = [NSMutableSet set];
    L.preScanRestDone = [NSMutableSet set];
    L.structLayouts = [NSMutableDictionary dictionary];
    L.globalsByName = [NSMutableDictionary dictionary];
    // Module-scoped, NOT per-function: resetting this per function would emit a
    // fresh trampoline each time, and two `^`s widened from the same function in
    // different functions would carry DIFFERENT code words and compare unequal.
    L.boundTrampolines = [NSMutableDictionary dictionary];
    L.weakGlobals = [NSMutableDictionary dictionary];
    L.stringLiterals = [NSMutableDictionary dictionary];
    L.pendingGlobalInits = [NSMutableArray array];
    L.staticDataByClass = [NSMutableDictionary dictionary];
    L.staticInitFlagByClass = [NSMutableDictionary dictionary];
    // Race-free static-init once: forced by -f[no-]thread-safe-arc, else on
    // exactly when this program can spawn a thread. See sThreadSafeStatics.
    L.threadSafeStatics = (sThreadSafeStatics >= 0)
                              ? (sThreadSafeStatics != 0)
                              : XTProgramDeclaresThreadCreate(program);

    // Index every class decl by name so the pre-scan can walk parent
    // chains via `parentName` even when sema didn't populate
    // `parentClass` yet (defensive — sema does populate it, but the
    // dictionary is cheap and a useful fallback).
    L.protocolDeclsByName = [NSMutableDictionary dictionary];
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind == XTASTNodeKindClassDecl)
            {
            XTClassDeclNode* cls = (XTClassDeclNode*)decl;
            L.classDeclsByName[cls.className] = cls;
            }
        else if ([decl isKindOfClass:[XTProtocolDeclNode class]])
            {
            XTProtocolDeclNode* p = (XTProtocolDeclNode*)decl;
            if (p.protocolName.length)
                L.protocolDeclsByName[p.protocolName] = p;
            }
        }

    // Assign each class a dense RTTI id (1..N, sorted by name so the
    // numbering is deterministic; 0 stays the "no class" sentinel). The
    // ids are used only within the lowering — `new` stamps one into the
    // instance and the downcast checks it — so they need only be
    // self-consistent (they mirror sema's scheme for readability).
    L.classIdByName = [NSMutableDictionary dictionary];
        {
        NSArray<NSString*>* sortedNames =
            [L.classDeclsByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSUInteger nextId = 1;
        for (NSString* cn in sortedNames)
            L.classIdByName[cn] = @(nextId++);
        }

    // Register enum constants (name → value) so identifier references and
    // switch case labels resolve to a compile-time Const.
    L.enumConstants = [NSMutableDictionary dictionary];
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind != XTASTNodeKindEnumDecl)
            continue;
        for (XTEnumMemberNode* m in ((XTEnumDeclNode*)decl).members)
            {
            L.enumConstants[m.memberName] = @(m.resolvedValue);
            }
        }

    // Pre-scan classes BEFORE functions, because a top-level function
    // may take a class-pointer parameter or call `new T` — those need
    // the class's layout / vtable / method symbols visible.
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind == XTASTNodeKindClassDecl)
            {
            [L preScanClass:(XTClassDeclNode*)decl];
            }
        }

    // Pre-scan: create the XTIRFunction skeleton (with empty entry
    // block) and module symbol for every top-level function decl
    // with a body, so direct calls can resolve to a SymbolId at any
    // point during the body-lowering pass.
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind != XTASTNodeKindFunctionDecl)
            continue;
        [L preScanFunction:(XTFunctionDeclNode*)decl];
        }

    // Top-level variable declarations become DataGlobal symbols.
    // Register them before any function body lowers so identifier
    // references in those bodies can resolve to a symbol-id.
    for (XTASTNode* decl in program.declarations)
        {
        if (decl.nodeKind != XTASTNodeKindVariableDecl)
            continue;
        [L preScanGlobalVariable:(XTVariableDeclNode*)decl];
        }

    // ARC: classify which functions/methods return a RETAINED (+1) class
    // pointer (task #123). Needs the whole program (fixpoint over the call
    // graph) and runs before any body lowers so the temp-release path can
    // query it at every call site.

    for (XTASTNode* decl in program.declarations)
        {
        switch (decl.nodeKind)
            {
        case XTASTNodeKindFunctionDecl:
            [L lowerFunction:(XTFunctionDeclNode*)decl];
            break;
        case XTASTNodeKindClassDecl:
            [L lowerClass:(XTClassDeclNode*)decl];
            break;
        // Tolerate-and-ignore: the prescan walked them so symbol
        // resolution sees them (where relevant). Full lowering of
        // these constructs is their own task.
        case XTASTNodeKindStructDecl:
        case XTASTNodeKindTypedefDecl:
        case XTASTNodeKindEnumDecl:
        case XTASTNodeKindUseDecl:
        case XTASTNodeKindProtocolDecl:
            break;
        case XTASTNodeKindVariableDecl:
            // Already handled by the pre-scan loop above — the
            // symbol is registered + cached. Init values are
            // deferred to a follow-up task.
            break;
        default:
            [diag emitError:[NSString stringWithFormat:
                                          @"lowering: unsupported top-level declaration kind %ld",
                                          (long)decl.nodeKind]
                         at:decl.location];
            break;
            }
        }

    if (diag.hasFatalError)
        return nil;

    // Class destructors are dispatched INDIRECTLY: the runtime emitter
    // (XTIRRuntimeEmitter) materialises `<Class>$dealloc`'s address into
    // every object header at `new` time, so there is no IR-level call
    // edge to a dealloc body. Mark every dealloc function symbol
    // `escapes` (its address genuinely is taken, just not by an IR insn)
    // so dead-function-elim — which roots escaping function symbols and
    // round-trips the flag through the IR text (Task #229) — keeps them.
    // Without this, DFE at -O1+ drops every dealloc and ARC teardown
    // silently no-ops (refcounts/dealloc counters never update). The
    // `$dealloc` suffix is the same naming contract the runtime keys on.
    for (XTIRSymbol* sym in L.module.symbols)
        {
        if (sym.kind == XTIRSymbolKindFunction &&
            [sym.name hasSuffix:@"$dealloc"] && !sym.escapes)
            {
            [sym setValue:@(YES) forKey:@"escapes"];
            }
        }

    // Deferred global initialisers nobody ran: this module never lowered a
    // main, so the stores had nowhere to go — the old zero-slot warning is
    // exactly right again, per leftover.
    for (XTVariableDeclNode* g in L.pendingGlobalInits)
        {
        [L.diag emitWarning:[NSString stringWithFormat:
                                          @"global '%@' initialiser is not constant-foldable and this module "
                                          @"has no main to run it — the slot is zero-initialised and will "
                                          @"read back as zeros at runtime",
                                          g.varName]
                         at:g.location];
        }
    return L.module;
    }

@end
