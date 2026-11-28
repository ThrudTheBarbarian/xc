/****************************************************************************\
|* XTArm64Link.h — what an arm64 link adds to the program's asm: the per-class
|* `new` allocators, and the guard word's reach through the GOT when the
|* runtime is libRuntime's.
|*
|* `new T[n]` of an aggregate element lowers to `__xtc_new_<T>`, which is
|* program-specific, so the runtime (rt-macos.s and its kin) cannot ship it.
|* The driver synthesises one stub per name it finds in the program's asm, and
|* the corpus sweep links its arm64 programs with the same stubs and rewrites,
|* so the two cannot drift.
|*
|* Header-only and static inline, like XTRegexCompat.h: the driver and the
|* sweep are separate binaries with separate object lists.
\****************************************************************************/

#ifndef XTARM64LINK_H
#define XTARM64LINK_H

#import <Foundation/Foundation.h>
#import "ir/XTIRElemKind.h"

// Each stub is a short tail call into the runtime's allocator, for the
// executable and shared-library paths alike.
static inline NSString* _Nonnull XTArm64ClassAllocStubs(NSString* _Nullable prog)
    {
    NSMutableString* out = [NSMutableString string];
    if (!prog)
        return out;
    NSRegularExpression* re = [NSRegularExpression
        regularExpressionWithPattern:@"__xtc_new_([A-Za-z_][A-Za-z0-9_]*)"
                             options:0
                               error:NULL];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSTextCheckingResult* m in [re matchesInString:prog options:0 range:NSMakeRange(0, prog.length)])
        {
        NSString* cls = [prog substringWithRange:[m rangeAtIndex:1]];
        if (XTIRIsPrimitiveElemName(cls) || [seen containsObject:cls])
            continue;
        [seen addObject:cls];
        [out appendFormat:@".text\n.globl __xtc_new_%@\n.align 2\n__xtc_new_%@:\n", cls, cls];
        // Only an aggregate element reaches here (a class allocates through
        // _xtc_alloc_object), and an aggregate has no dealloc, so every object
        // carries the SAME body: no hook, and an array of 64 KB or more is
        // page-aligned and registered as a numeric one is, so a par block can
        // size it and share it with the GPU (#113). A link may then keep any
        // object's copy (#663). The port's classAllocStubs.
        [out appendFormat:@"    mul x9, x0, x1\n    mov x2, #0\n    lsr x10, x9, #16\n    cbz x10, L__xtc_new_%@_small\n"
                          @"    b __xtc_alloc_aligned\nL__xtc_new_%@_small:\n    b __xtc_alloc\n",
                          cls, cls];
        }
    return out;
    }

// The stack canary's guard word is the runtime's: an image that takes
// libRuntime reaches it through the GOT. As the port's guardThroughGot.
static inline NSString* _Nonnull XTArm64GuardThroughGot(NSString* _Nonnull prog)
    {
    NSString* a = [prog stringByReplacingOccurrencesOfString:@"    adrp x16, ___xt_stack_guard@PAGE\n    ldr x16, [x16, ___xt_stack_guard@PAGEOFF]\n"
                                                  withString:@"    adrp x16, ___xt_stack_guard@GOTPAGE\n    ldr x16, [x16, ___xt_stack_guard@GOTPAGEOFF]\n    ldr x16, [x16]\n"];
    return [a stringByReplacingOccurrencesOfString:@"    adrp x17, ___xt_stack_guard@PAGE\n    ldr x17, [x17, ___xt_stack_guard@PAGEOFF]\n"
                                        withString:@"    adrp x17, ___xt_stack_guard@GOTPAGE\n    ldr x17, [x17, ___xt_stack_guard@GOTPAGEOFF]\n    ldr x17, [x17]\n"];
    }

#endif
