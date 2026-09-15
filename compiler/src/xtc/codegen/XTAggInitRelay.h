// XTAggInitRelay.h — re-lay an aggregate's constant initial bytes from the
// IR layout into a backend's own layout.
//
// The front end folds a global aggregate's initialiser into bytes placed at
// the *IR layout's* field offsets, using the target's canonical widths (a
// pointer is 2 bytes on arm64, 3 on xt6502 — XTPointerType sizes it per
// target). A backend is free to use a different layout, and the native ones
// do: XTArm64Backend recomputes every field offset from arm64FieldWidth
// (Ptr → 8), m68k from m68kFieldWidth (Ptr → 4), and so on. That's fine —
// each backend is internally consistent, since the same width function drives
// FieldAddr, the global's reserved size, and the frame slots.
//
// But it means the initialiser image has to be translated into whichever
// layout the backend actually reads. That is this file's whole job: walk the
// IR layout, copy each leaf from its IR offset to the backend's offset for
// the same field, and widen (zero-extend) a pointer leaf to the backend's
// pointer width. xt6502 reads the IR layout's offsets directly and its widths
// already match, so it needs no relay.
#import <Foundation/Foundation.h>

@class XTIRLayout;
@class XTIRType;

NS_ASSUME_NONNULL_BEGIN

@interface XTAggInitRelay : NSObject

/****************************************************************************\
|* Translate `src` — an aggregate initialiser laid out per `layout` — into the
|* backend layout implied by `widthOfLeaf`, recursing through nested
|* aggregates (an array of structs is Agg(array) over Agg(struct)).
|*
|* Integer and pointer leaves are copied low-byte-first and zero-extended into
|* the backend's (possibly wider) slot, so a 2-byte null pointer becomes an
|* 8-byte null on arm64.
|*
|* Float leaves need no conversion: the front end is told the target and bakes
|* them in ITS float format already (IEEE f32/f64 everywhere but xt6502, which
|* keeps xtc's 5-byte form) — see XTType.floatIsIEEE. All this has to do is
|* place them, and reverse them on a big-endian target.
|*
|* When `bigEndian` is YES each leaf is reversed after placement, which is what
|* m68k needs — the IR image is always little-endian.
|*
|* @param src         The IR-laid-out initialiser bytes. A short image (a
|*                    brace list with a missing tail) is fine: bytes past its
|*                    end read as zero.
|* @param layout      The IR layout `src` was built against.
|* @param widthOfLeaf The backend's byte width for a given IR type — pass the
|*                    same function the backend uses for FieldAddr, or the
|*                    relayed image won't match where it reads.
|* @param bigEndian   YES to byte-reverse each leaf after placing it.
|* @return The initialiser in the backend's layout, sized to the backend's
|*         aggregate footprint.
\****************************************************************************/
+ (NSData*)relay:(NSData*)src
          layout:(XTIRLayout*)layout
     widthOfLeaf:(NSUInteger (^)(XTIRType* type))widthOfLeaf
       bigEndian:(BOOL)bigEndian;

@end

NS_ASSUME_NONNULL_END
