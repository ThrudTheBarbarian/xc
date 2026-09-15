#import <Foundation/Foundation.h>
#import "XTASTNode.h"
#import "XTDeclNodes.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTScope.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTSemanticAnalyzer : NSObject <XTASTVisitor>

// --migrate=<base>:<to> (driver-set, applies to every analyzer instance):
// see migrateBase in the private header.
+ (void)setMigrateBaseVersion:(NSString* _Nullable)base;
// The resolved support tree (uxkit/025). Files under it ship WITH the compiler,
// so they are already written against its version and `--migrate` must not hide
// the new surface from them — otherwise any program importing an
// already-migrated stdlib class cannot use the flag at all. Pass nil to clear.
+ (void)setMigrateSupportRoot:(NSString* _Nullable)root;

@property(nonatomic, readonly) XTScope* globalScope;

/****************************************************************************\
|* The heap allocator in effect for this compilation (@"bump" or @"heap").
|* The sema pass uses this to reject `delete` on targets where the
|* free-list allocator isn't available (bump-only targets, where freeing
|* is a no-op). Defaults to @"bump". Driver sets it from the options.
\****************************************************************************/
@property(nonatomic, copy) NSString* allocator;

/****************************************************************************\
|* First heap bank reserved by the active memory model (0 = non-banked
|* heap target). Used by visitNewExpr to decide whether a `new T(…)`
|* expression returns a banked pointer (3 bytes, placement=banked)
|* or a classic main-RAM pointer (2 bytes, placement=main).
\****************************************************************************/
@property(nonatomic) uint16_t heapBank;

/****************************************************************************\
|* Library build (`--emit-lib`), set by the driver.
|*
|* Virtuality is inferred whole-program: a method only earns a vtable slot
|* when some subclass IN THIS COMPILATION overrides it, and everything else
|* keeps a direct call. That inference is unsound when the program isn't
|* whole — under --emit-lib the overrides live in a client that doesn't
|* exist yet, so a method nothing overrides inside the library would be
|* devirtualised and an app's override could never be reached.
|*
|* So when this is set, every instance method of every class gets a slot.
|* The optimisation is only sound for a closed program. A future `final`
|* keyword can restore it as an opt-in.
\****************************************************************************/
@property(nonatomic) BOOL libraryBuild;
/****************************************************************************\
|* YES for `--emit-lib` specifically — this compilation IS the library.
|*
|* Deliberately NOT the same flag as libraryBuild, which asks the broader
|* question "is the program closed?" and which a separately-compiled object
|* has just as much reason to set. The one rule that needs THIS question is
|* separate-compilation §4.2's: only the FINAL LINK may add a category to a
|* class from another module, so a `.so` must be refused and a `-c` object —
|* which is still part of a final link — must not be.
\****************************************************************************/
@property(nonatomic) BOOL emittingLibrary;
// YES when the target passes varargs in registers (AAPCS — arm9) rather than
// through the shared pack buffer every other target uses. Decides whether the
// `...` forwarding form can work at all. private:docs/bugs/047.
@property(nonatomic) BOOL nativeVarargs;

/****************************************************************************\
|* Automatic Reference Counting gate, mirroring the `-farc` driver flag.
|* When NO, the `retain` and `release` statements are rejected with a
|* diagnostic directing the user to re-enable ARC. `delete` is not
|* gated here — it's an explicit free-or-decrement and stays legal
|* regardless of ARC being on or off. Defaults to YES; driver sets it
|* from the options.
\****************************************************************************/

/****************************************************************************\
|* Initialise the semantic analyser with a type table and diagnostic engine.
|* @param typeTable    The global type registry for resolving type names.
|* @param diagnostics  The diagnostic engine for errors and warnings.
|* @return  A fully initialised analyser ready for -analyzeProgram:.
\****************************************************************************/
- (instancetype)initWithTypeTable:(XTTypeTable*)typeTable
                      diagnostics:(XTDiagnosticEngine*)diagnostics NS_DESIGNATED_INITIALIZER;

// analyzeProgram: lives on XTSemanticAnalyzer (Analysis) — see header imported below.

/****************************************************************************\
|* Per-function static-frame eligibility, keyed by the call-graph label
|* (`_fn_<mangled>` for free functions, `_cls_<Class>_<mangled>` for
|* methods). Value is @YES when the function's frame save can bypass
|* the xtc software stack and write to a fixed slot in the layout's
|* `[buffers] stack` region; @NO (or absent) when it must use the
|* existing xtc-stack path.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* staticFrameEligible;

/****************************************************************************\
|* Labels of every function whose address was taken via `&funcName`
|* anywhere in the program. Populated in Pass A of the static-frame
|* analyser (via `visitUnaryExpr` on `XTUnaryOpAddrOf`). Codegen reads
|* this to force banked-target placement to `:main` — the indirect
|* JSR trampoline can't do bank switching, so any function reachable
|* through a pointer must live in always-visible main RAM.
\****************************************************************************/
@property(nonatomic, readonly) NSSet<NSString*>* addressTakenFunctions;

/****************************************************************************\
|* Labels flagged as recursive by `detectRecursiveFunctions` (direct
|* self-loop or any back-edge reaching the label via `_callEdges`).
|* Exposed so the manifest emitter can serialise an `is_recursive`
|* attribute per function.
\****************************************************************************/
@property(nonatomic, readonly) NSSet<NSString*>* recursiveFunctions;

/****************************************************************************\
|* Per-label max call depth — length of the longest acyclic forward
|* path rooted at the label through `_callEdges`. 0 for leaf functions;
|* capped for recursive participants (left unset rather than filled
|* with a sentinel). Exposed for manifest export and future budget
|* checks against the layout's static-frame buffer.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* maxCallDepth;

/****************************************************************************\
|* PR8 virtual-dispatch metadata. `classIdsByName` assigns a dense
|* 0..N-1 class id per class (sorted by name for determinism); the
|* class-id byte stamped at payload offset 0 of every instance
|* indexes into the per-class vtable pointer tables at runtime.
|* `virtualSlotByLabel` maps every method that participates in a
|* virtual group (the root + every override) to its global vtable
|* slot. `virtualImplByClassAndSlot[className][slot] = label` names
|* the concrete method body to run when slot `slot` is dispatched
|* on an instance whose class-id maps to `className`. Codegen
|* consumes all three to emit __vtable_<Class> tables and
|* _virtual_dispatch call sites.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* classIdsByName;
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* virtualSlotByLabel;
@property(nonatomic, readonly) NSDictionary<NSString*, NSDictionary<NSNumber*, NSString*>*>* virtualImplByClassAndSlot;
@property(nonatomic, readonly) NSUInteger totalVirtualSlots;
/****************************************************************************\
|* protocol → (method → vtable slot). Read out for --emit-lib serialisation.
\****************************************************************************/
@property(nonatomic, readonly, nullable) NSDictionary* protocolMethodSlotsForExport;

/****************************************************************************\
|* Virtual-slot indices ADOPTED from imported xtc libraries.
|*
|* Slots used to be numbered 0,1,2… by walking THIS unit's override-root labels
|* in sorted order. A library and its client have different label sets — and
|* under --emit-lib EVERY instance method becomes an override root — so the same
|* protocol method landed in a DIFFERENT slot in each. Dispatch through a
|* `Proto@` receiver then read the wrong slot and jumped to garbage. That breaks
|* the delegate pattern precisely where it is most wanted: across a .so.
|*
|* A library's numbering is authoritative: its vtables are already emitted. The
|* client seeds these and numbers its OWN labels above the highest imported one.
|* `importedProtocolSlots` is protocol → (method → slot); `importedMethodSlots`
|* is label → slot.
\****************************************************************************/
@property(nonatomic, nullable) NSDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* importedProtocolSlots;
@property(nonatomic, nullable) NSDictionary<NSString*, NSNumber*>* importedMethodSlots;

/****************************************************************************\
|* Dispatch protocols through a per-class ITABLE keyed by a protocol id, instead
|* of a slot in the flat, program-global vtable numbering.
|*
|* Set on targets that can be linked as MULTIPLE MODULES (arm9 .so today). There,
|* a global slot number is unachievable: two independently built libraries number
|* their protocols from the same base without knowing the other exists, and a
|* class conforming to both cannot satisfy either — and it cannot be fixed by
|* renumbering, because each library's vtables are already emitted and its own
|* dispatch sites already bake its numbers in.
|*
|* With this on, protocol slots stay a purely LOCAL layout detail (they still lay
|* out the class's own vtable and keep the impls reachable) and are never seeded
|* across modules nor dispatched through. Whole-program targets leave it off and
|* keep the flat slot — correct, free, and nothing to collide with.
\****************************************************************************/
@property(nonatomic) BOOL itableProtocols;

// The backend carries a per-class conformance itable (protocol-id list) reachable
// from the vtable, so a runtime `(P@ ?)obj` conformance downcast is supported. ON
// for the flat cross-`.so` backends; arm9 gets it via itableProtocols. When
// neither is set (xt6502/m68k) a non-statically-provable protocol downcast is
// rejected at compile instead of stamped for a runtime check.
@property(nonatomic) BOOL vtableConforms;

/****************************************************************************\
|* Cross-module function attributes imported from `.asm` manifests
|* present in the driver's input list. Keys are call-graph labels
|* (`_fn_<mangled>` / `_cls_<Class>_<mangled>`); values are attribute
|* dictionaries produced by `XTModuleManifest parseFunctionsFromAsmText:`
|* (with decoded NSNumber booleans and integers). Set by the driver
|* before `analyzeProgram:`; imported labels are promoted out of
|* `_externalFunctions` and their `is_recursive` / `address_taken`
|* flags are merged into the local sets so the static-frame pass sees
|* the same information a single-unit compile would.
\****************************************************************************/
@property(nonatomic, nullable, copy) NSDictionary<NSString*, NSDictionary*>* importedFunctionAttrs;

/****************************************************************************\
|* xt extended-RAM analysis (PR1 of doc/xt-extended-ram.md). Parallels
|* the existing stackUsingFunctions / locallyStackUsingFunctions.
|*
|* `regionCLocallyUsing` — labels of functions whose own body
|*   locally touches region C ($7000-$7FFF, selected by the $84/$85
|*   pair on xt-extended). Today's signals: inline-asm blocks
|*   referencing $84/$85. PR2 adds packer-driven flagging when a
|*   banked allocation lands in region C.
|*
|* `regionCUsing` — transitive closure over `_callEdges` (every
|*   function that can reach a region-C user). Used by program-wide
|*   gates (ZP reservation of $84/$85, heap.asm region-C variant,
|*   _xcall trampoline shape).
|*
|* Both empty on legacy xt / xe / xl. xt-extended layouts that never
|* exercise region C also leave them empty — pay-for-what-you-use is
|* automatic.
\****************************************************************************/
@property(nonatomic, readonly) NSSet<NSString*>* regionCLocallyUsing;
@property(nonatomic, readonly) NSSet<NSString*>* regionCUsing;

/****************************************************************************\
|* Auto-cloak inference (xe-family targets). Per-function safety verdict:
|* @YES means the codegen could safely place this function/method in the
|* `:cloaked` library segment ($4000-$7FFF main RAM, accessed with
|* PORTB=$30 = banking off, xtc software stack invisible) without
|* changing program behaviour. The verdict is conservative — false
|* negatives leave savings on the table; false positives would crash at
|* runtime, so the analysis errs heavily toward "not safe" whenever it
|* can't prove safety.
|*
|* A function is `cloakInferredSafe` iff:
|*   - not varargs (xtc-stack arg-walk is required)
|*   - all params total ≤ XT_ARG_WINDOW_SIZE bytes (no caller-side
|*     spill-buffer needed)
|*   - `staticFrameEligible` (locals fit in fixed ZP slots, no spill to
|*     (SP),Y)
|*   - body has no inline-asm that touches $89/$8A or `(SP),Y` patterns
|*   - all transitive callees are also cloakInferredSafe (fixed-point
|*     over `_callEdges`)
|*
|* Codegen reads this to auto-promote eligible decls to
|* XTPlacementCloaked when the user asks for it (`-fauto-cloak=always`)
|* or when main code overflow is detected (`-fauto-cloak=auto`,
|* default). Empty / not-set on flat targets (xl-family) — cloaked
|* requires PORTB banking which xl doesn't have.
\****************************************************************************/
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* cloakInferredSafe;

/****************************************************************************\
|* Ordered list of class names brought into bare-call lookup scope by
|* `use Klass;` directives encountered so far. Read-only public view
|* of the internal mutable list; visitCallExpr uses this when the
|* free-function lookup misses.
\****************************************************************************/
@property(nonatomic, readonly) NSArray<NSString*>* usedClassNames;

@end

NS_ASSUME_NONNULL_END

// Category headers — imported here so consumers see the full method set.
#import "XTSemanticAnalyzer+Analysis.h"
#import "XTSemanticAnalyzer+ZPSafety.h"
#import "XTSemanticAnalyzer+Overload.h"
