#import <Foundation/Foundation.h>
#import "XTDeclNodes.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Reachability-based dead-code filter.
|*
|* Builds the call graph from the AST (using sema's already-resolved
|* mangled names) and computes the transitive closure of calls from
|* a set of roots. Codegen consults the result to skip emission of
|* any user function / class method that is provably unused — letting
|* big libraries like Math.xc stay full-featured without every user
|* program paying the code-size cost of every overload at O0 / O2.
|*
|* Roots (start points for the worklist):
|*   • main
|*   • any class whose `init` method exists — always kept, since it's
|*     auto-called on first method use
|*   • any function / method whose address is taken via `&` in source
|*   • any label referenced by `JSR <label>` / `jsr <label>` inside
|*     an inline `asm { }` block that resolves to a known user label
|*
|* Not handled (future work, or unnecessary for xtc today):
|*   • virtual dispatch / polymorphism — xtc is monomorphic
|*   • function pointer through generics / templates — n/a
|*
|* Runtime support routines (fpAdd, dpMul, etc.) are NOT filtered by
|* this pass — they're already pulled in on demand via the per-target
|* `_requiredRuntimeRoutines` set. The reachability set here covers
|* user-written functions and class methods only.
\****************************************************************************/
@interface XTReachabilityAnalyzer : NSObject

- (instancetype)initWithProgram:(XTProgramNode*)program NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/****************************************************************************\
|* sema's full `virtualSlotByLabel` mapping — `_cls_<C>_<m>` → slot
|* index for every method that occupies a vtable slot, plus the
|* base-class root labels for protocol methods. The analyser uses
|* it two ways:
|*
|*  1. as a label set (key set) for the dead-stub trim — methods
|*     in the map can't be dropped purely on "no reachable AST
|*     call references this label", since a virtual dispatch could
|*     reach them through the vtable;
|*
|*  2. as a slot lookup — when walking the AST, every virtual
|*     call site maps to a slot, and every `new C` records C as
|*     instantiated. The reachable-vtable-method set is the
|*     cross product of the two: for each (slot, instantiated
|*     class) pair where the slot is virtually called somewhere
|*     in reachable code AND the class has a method filling
|*     that slot (walking ancestors), the method is marked
|*     reachable. Slots with no virtual call site are pruned
|*     even though they appear in this map.
\****************************************************************************/
@property(nonatomic, nullable, copy) NSDictionary<NSString*, NSNumber*>* virtualSlotByLabel;

/****************************************************************************\
|* Compute and return the set of reachable asm labels. Each entry
|* has the form:
|*   "_fn_<mangled>"   — free function
|*   "_cls_<Class>_<mangled>"  — class method
|*
|* Safe to call multiple times; the result is cached after the first
|* call.
\****************************************************************************/
- (NSSet<NSString*>*)reachableLabels;

/****************************************************************************\
|* Set of class names that are reachably instantiated — every class C
|* with a `new C(...)` site inside transitively-reachable code (or a
|* `new T[N]` of class element type, etc.). Populated as a side effect
|* of `reachableLabels`; call after that.
|*
|* Codegen reads this to decide which classes warrant emitting a vtable
|* block and a real `__class_vtable_lo/hi_table` slot. A class that's
|* declared but never instantiated has no instance carrying its class-
|* id at runtime, so its vtable is unreachable through `_virtual_dispatch`
|* and its slot can collapse to $00,$00. Saves
|* totalVirtualSlots × stride bytes per dead class.
\****************************************************************************/
- (NSSet<NSString*>*)instantiatedClassNames;

@end

NS_ASSUME_NONNULL_END
