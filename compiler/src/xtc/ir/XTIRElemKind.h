// XTIRElemKind.h — the one place that decides whether `new T[N]` allocates a
// PRIMITIVE element or an aggregate one.
//
// This is a CONTRACT between two pieces of code that never see each other:
//
//   - the IR lowering picks the call shape — `_xtc_new_T(count)` for a
//     primitive, `_xtc_new_T(count, stride)` for a struct;
//   - the driver's stub generators (xtc/main.m, arm64 and arm9) synthesise the
//     matching C function by scanning the generated ASM TEXT for the symbol,
//     with no type information at all — only the name.
//
// They agreed by each keeping their own copy of the list, until the lowering
// stopped passing the stride and nothing caught it: the struct stub read a
// second argument that was never set, so `calloc` got a garbage size, failed,
// and the header was written through the returned NULL. arm9 took a DATA-ABORT
// at address zero; arm64 happened to hold something small in that register and
// worked. Bug 027.
//
// A primitive's width is per-BACKEND (a pointer is 3, 4 or 8 bytes depending on
// the target), so the shared lowering genuinely cannot compute it and the stub
// bakes it in. A struct's size is the IR layout's and is known on both sides —
// so it is passed, like the class path already passes it.
#ifndef XTIRELEMKIND_H
#define XTIRELEMKIND_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when `name` is a primitive element type — the `_xtc_new_<name>(count)`
/// one-argument form. NO means an aggregate: the two-argument
/// `_xtc_new_<name>(count, stride)` form.
///
/// Inline in the header on purpose: `xtc` is a thin dispatcher that links only
/// its own driver-core objects, not the IR library, so a separate translation
/// unit would not reach it — and the whole point is that the lowering and the
/// stub generator share ONE list.
static inline BOOL XTIRIsPrimitiveElemName(NSString* _Nullable name)
    {
    static NSSet<NSString*>* prims;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      prims = [NSSet setWithArray:@[ @"pointer", @"bool", @"i8", @"u8",
                                     @"i16", @"u16", @"i32", @"u32", @"float", @"double", @"string" ]];
    });
    return name != nil && [prims containsObject:name];
    }

NS_ASSUME_NONNULL_END

#endif
