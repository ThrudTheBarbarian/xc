#import "XTPointerType.h"

@implementation XTPointerType

static NSUInteger sHeapPointerWidth = 2;

static NSUInteger sHeapCountWidth = 2;

+ (NSUInteger)heapPointerWidth
    {
    return sHeapPointerWidth;
    }

+ (NSUInteger)heapCountWidth
    {
    return sHeapCountWidth;
    }

+ (void)setHeapCountWidth:(NSUInteger)width
    {
    NSAssert(width == 2 || width == 4 || width == 8,
             @"heapCountWidth must be 2, 4 or 8, got %lu", (unsigned long)width);
    sHeapCountWidth = width;
    }

+ (void)setHeapPointerWidth:(NSUInteger)width
    {
    NSAssert(width == 2 || width == 3 || width == 4 || width == 8,
             @"heapPointerWidth must be 2, 3, 4, or 8, got %lu", (unsigned long)width);
    sHeapPointerWidth = width;
    }

static NSString* prefixForPlacement(XTPointerPlacement p)
    {
    switch (p)
        {
    case XTPointerPlacementMain:
        return @"";
    case XTPointerPlacementShadow:
        return @"shadow:";
    case XTPointerPlacementBanked:
        return @"banked:";
    case XTPointerPlacementHeap:
        return @""; // user-indistinguishable from Main
    case XTPointerPlacementRaw:
        return @"raw:";
        }
    return @"";
    }

/****************************************************************************\
|* Internal initialiser. Builds display name as
|* "<weakPrefix><placementPrefix><pointee>@". `weak:` always leads
|* (it's the semantic qualifier) so the placement prefix nests
|* inside: `weak:banked:Foo@`. Sema currently rejects that combo,
|* but the type's displayName has to render it so the diagnostic's
|* printed form matches the user's source.
|* @param pointee    The type this pointer points to.
|* @param placement  Where the pointee physically lives.
|* @param isWeak     Whether the pointer skips ARC retain/release.
|* @return A new pointer type.
\****************************************************************************/
- (instancetype)initWithPointeeType:(XTType*)pointee
                          placement:(XTPointerPlacement)placement
                             isWeak:(BOOL)isWeak
    {
    NSString* name = [NSString stringWithFormat:@"%@%@%@*",
                                                isWeak ? @"weak:" : @"",
                                                prefixForPlacement(placement),
                                                pointee.displayName];
    self = [super initWithKind:XTTypeKindPointer displayName:name];
    if (self)
        {
        _pointeeType = pointee;
        _placement = placement;
        _isWeak = isWeak;
        }
    return self;
    }

/****************************************************************************\
|* Create a typed pointer with default (main-RAM) placement.
\****************************************************************************/
+ (instancetype)pointerToType:(XTType*)pointee
    {
    return [[self alloc] initWithPointeeType:pointee
                                   placement:XTPointerPlacementMain
                                      isWeak:NO];
    }

+ (instancetype)pointerToType:(XTType*)pointee
                    placement:(XTPointerPlacement)placement
    {
    return [[self alloc] initWithPointeeType:pointee
                                   placement:placement
                                      isWeak:NO];
    }

+ (instancetype)pointerToType:(XTType*)pointee
                    placement:(XTPointerPlacement)placement
                       isWeak:(BOOL)isWeak
    {
    return [[self alloc] initWithPointeeType:pointee
                                   placement:placement
                                      isWeak:isWeak];
    }

/****************************************************************************\
|* Front-end pointer width, keyed on placement:
|*   • banked / raw   → 3  ([addr-lo, addr-hi, bank-lo])
|*   • heap           → sHeapPointerWidth (2, 3, or 4 — set per target)
|*   • main / shadow  → 2  (16-bit address, no bank)
|* This is the width the parser/sema use for struct field offsets,
|* sizeof, and IR-layout sizing. Each target lowers its own module with
|* a matching placement default + heapPointerWidth (e.g. xt6502 uses
|* placement=Heap + heapPointerWidth=3 so every pointer is 3 bytes,
|* matching XT6502Backend's uniform 3; arm64 uses placement=Main + width
|* 2 and recomputes real slot widths in its own backend). isWeak has no
|* effect on width — a weak pointer is the same size as its strong
|* equivalent; only the emit behaviour at assign / scope-exit differs.
\****************************************************************************/
- (NSUInteger)byteWidth
    {
    // Banked and raw pointers are [addr-lo, addr-hi, bank-lo] — 3 bytes — on
    // the banked target. On a FLAT host the bank byte means nothing and the
    // backend stores a banked pointer exactly like any other (8 on arm64/
    // x86_64, 4 on m68k/arm9), so the front end must report the native width
    // there or the recorded struct offsets under-place every later field —
    // which the backends' old offset recompute silently papered over, and
    // reading recorded offsets (blewit #5) exposed as a segfault
    // (banked_array_ivar_subscript). MAX keeps 3 for xt6502 (native width 3)
    // and for the unconfigured unit-test default (2).
    if (_placement == XTPointerPlacementBanked ||
        _placement == XTPointerPlacementRaw)
        {
        return MAX(sHeapPointerWidth, (NSUInteger)3);
        }
    // Every other placement is the target's native pointer (8 on arm64 and
    // x86-64, 4 on m68k/arm9, 3 on xt6502). This used to hardcode 2 for
    // Main/Shadow, which made `sizeof(u8@)` report 2 on arm64 while the backend
    // laid pointers out 8 wide — so a struct with a pointer member got a 2-byte
    // slot in the AST/IR layout and the 64-bit store ran off the end of it.
    return sHeapPointerWidth;
    }
- (BOOL)isPointerLike
    {
    return YES;
    }

@end
