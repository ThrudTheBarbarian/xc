#import "XTType.h"

NS_ASSUME_NONNULL_BEGIN

/****************************************************************************\
|* Placement qualifier attached to a pointer type. Determines where the
|* pointee physically lives, which in turn dictates the pointer's byte
|* width and how the codegen emits loads/stores through it.
|*
|*   XTPointerPlacementMain   — points into main RAM (the default on
|*                              non-banked targets). 2-byte pointer.
|*   XTPointerPlacementShadow — points into shadow RAM under the OS ROM
|*                              (shadow-capable targets only). 2-byte.
|*   XTPointerPlacementHeap   — points into the implicit heap bank
|*                              (`heap_bank_first`) on banked-heap
|*                              targets. 2-byte pointer (bank is
|*                              implicit — the allocator only ever
|*                              hands out addresses in that bank). The
|*                              codegen brackets loads and stores in a
|*                              save-PORTB / select-heap-bank / deref /
|*                              restore-PORTB sequence, same mechanism
|*                              as XTPointerPlacementBanked but without
|*                              a runtime bank byte to stage.
|*   XTPointerPlacementBanked — points into a user-selected bank
|*                              (`banked:T@`). 3 bytes: high byte is
|*                              the bank id, low two bytes are the
|*                              address inside the bank window. Codegen
|*                              emits the same bracket as Heap but
|*                              sources the bank id from the pointer's
|*                              third byte.
|*   XTPointerPlacementRaw    — points into a user-selected bank
|*                              (`raw:T@`), same byte layout and deref
|*                              path as Banked, but excluded from ARC
|*                              entirely. Returned by the `bank()`
|*                              builtin for raw access to foreign-bank
|*                              data (sound, graphics, screendumps);
|*                              not subject to retain/release/delete.
\****************************************************************************/
typedef NS_ENUM(NSInteger, XTPointerPlacement) {
    XTPointerPlacementMain = 0,
    XTPointerPlacementShadow,
    XTPointerPlacementBanked,
    XTPointerPlacementHeap,
    XTPointerPlacementRaw,
};

@interface XTPointerType : XTType

@property(nonatomic, readonly) XTType* pointeeType;
@property(nonatomic, readonly) XTPointerPlacement placement;
/****************************************************************************\
|* YES if this pointer was declared with the `weak:T@` qualifier.
|* Weak pointers do not participate in ARC retain/release: assigning
|* to a weak slot registers the slot with the side-table runtime
|* (see support/xt6502/asm/weak/weak.asm) so the slot is zeroed
|* automatically when the pointee's refcount hits zero. Width is
|* unchanged by the qualifier — weak:T@ is the same 2/3 bytes as
|* the strong equivalent; only emit behaviour differs.
\****************************************************************************/
@property(nonatomic, readonly) BOOL isWeak;

/****************************************************************************\
|* Create a typed pointer (e.g. u8@, i16@). Display name is "<pointee>@".
|* Placement defaults to main (2-byte pointer). Use
|* `pointerToType:placement:` for a non-default placement.
|* @param pointee  The type this pointer points to.
|* @return A new pointer type with a 2-byte width.
\****************************************************************************/
+ (instancetype)pointerToType:(XTType*)pointee;

/****************************************************************************\
|* Create a typed pointer with an explicit placement qualifier.
|* A banked pointer is 3 bytes wide (bank + 2-byte address); main
|* and shadow pointers are 2 bytes. Display names pick up the
|* qualifier prefix when non-default: `banked:u8@` / `shadow:u8@`.
\****************************************************************************/
+ (instancetype)pointerToType:(XTType*)pointee
                    placement:(XTPointerPlacement)placement;

/****************************************************************************\
|* Create a pointer with an explicit placement AND weak qualifier.
|* Forwarded to by the two simpler factories with isWeak=NO, so
|* existing call sites keep their semantics. Display name becomes
|* `weak:<pointee>@` when weak; combining with a non-main placement
|* yields `weak:banked:...` but sema rejects that combination for
|* now — the factory itself doesn't enforce it because the type
|* system is shared between parse-time and codegen-internal
|* constructions.
\****************************************************************************/
+ (instancetype)pointerToType:(XTType*)pointee
                    placement:(XTPointerPlacement)placement
                       isWeak:(BOOL)isWeak;

/****************************************************************************\
|* Width of a Heap-placement pointer, in bytes. Default 2 — the
|* legacy implicit-bank-is-heap_bank_first layout. The compiler
|* driver writes the layout's `[heap] pointer-width = N` value
|* here once per program build, before sema and codegen run, so
|* `byteWidth` returns the right number for every freshly-created
|* Heap pointer type. Banked / Raw pointers stay at 3 regardless;
|* Main / Shadow stay at 2.
\****************************************************************************/
+ (NSUInteger)heapPointerWidth;

/****************************************************************************\
|* Bytes of element COUNT in the allocation header — what `.length` and
|* `for (v in heapPtr)` can read back. NOT the pointer width: arm9 and m68k
|* both have 4-byte pointers but 4- and 2-byte count fields. It was hard-wired
|* to 2 everywhere, so every array over 65535 elements reported `count &
|* 0xFFFF` on targets whose header holds far more (bug 234).
|*   8  arm64 / x86-64 / win64      4  arm9, wasm32
|*   2  m68k (its header field really is 2)  — xt6502 stores none and the
|*      `.length` path there soft-fails at compile time.
\****************************************************************************/
+ (NSUInteger)heapCountWidth;
+ (void)setHeapCountWidth:(NSUInteger)width;
+ (void)setHeapPointerWidth:(NSUInteger)width;

@end

NS_ASSUME_NONNULL_END
