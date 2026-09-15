#import <Foundation/Foundation.h>
@class XTIRFunction;

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Shared whole-function register-HOMING allocator for the stack-slot
|* backends (arm9 / x86_64 / m68k). Ports the arm64 backend's design:
|* give the most-used eligible SSA values a dedicated register for the
|* whole function, letting non-overlapping values share one (live-range
|* reuse). Values that don't get a register fall back to their stack slot
|* — there is NO spill code; homing is an optimistic overlay on the
|* existing stack-slot codegen.
|*
|* Two register tiers (the caller/callee-save split):
|*   - a value whose live range does NOT cross a call may use a CALLER-
|*     saved register (no prologue save cost);
|*   - a value that crosses a call needs a CALLEE-saved register.
|* Because the live intervals are a conservative over-approximation,
|* "crosses a call" errs toward YES → callee-saved → always sound.
|*
|* Register CLASS (GP vs FP) is taken from each value's IR type: F32/F64
|* home to the FP pools, everything else to the GP pools.
\****************************************************************************/
@interface XTHomingResult : NSObject
/// valueId → assigned register name. Absent ⇒ the value stays in its slot.
@property(nonatomic, readonly) NSDictionary<NSNumber*, NSString*>* homeReg;
/// Callee-saved registers actually used (stable priority order) — the
/// prologue/epilogue must save/restore exactly these (a backend that already
/// saves its whole callee-saved set can ignore this).
@property(nonatomic, readonly) NSArray<NSString*>* usedCalleeSaved;
@end

@interface XTHomingAllocator : NSObject
/****************************************************************************\
|* @param fn        the function to allocate over.
|* @param gpCallee  GP callee-saved pool, priority order.
|* @param gpCaller  GP caller-saved pool that is DISJOINT from the backend's
|*                  scratch registers (safe to home into), priority order.
|* @param fpCallee  FP callee-saved pool.
|* @param fpCaller  FP caller-saved pool (disjoint from FP scratch).
|* @param excluded  extra valueIds the backend forbids homing (e.g. pinned
|*                  locals). Address-taken values, aggregates, Memory/Void,
|*                  and never-read values are excluded automatically.
\****************************************************************************/
+ (XTHomingResult*)assignHomesForFunction:(XTIRFunction*)fn
                                 gpCallee:(NSArray<NSString*>*)gpCallee
                                 gpCaller:(NSArray<NSString*>*)gpCaller
                                 fpCallee:(NSArray<NSString*>*)fpCallee
                                 fpCaller:(NSArray<NSString*>*)fpCaller
                                 excluded:(nullable NSSet<NSNumber*>*)excluded;

/****************************************************************************\
|* As above, plus address folding. `foldInfo` maps a Load/Store's pointer
|* value-id → the ElementAddr/FieldAddr insn the backend will fold into that
|* Load/Store's memory operand. The addr op is elided, so its base/index are
|* read at the CONSUMING Load/Store — their live ranges are extended there so
|* the allocator does not reuse their register for the Load's own result (which
|* would corrupt a loop-invariant base pointer).
\****************************************************************************/
+ (XTHomingResult*)assignHomesForFunction:(XTIRFunction*)fn
                                 gpCallee:(NSArray<NSString*>*)gpCallee
                                 gpCaller:(NSArray<NSString*>*)gpCaller
                                 fpCallee:(NSArray<NSString*>*)fpCallee
                                 fpCaller:(NSArray<NSString*>*)fpCaller
                                 excluded:(nullable NSSet<NSNumber*>*)excluded
                                 foldInfo:(nullable NSDictionary<NSNumber*, id>*)foldInfo;
@end

NS_ASSUME_NONNULL_END
